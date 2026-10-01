// The device run for #69 (doc/tree-traversal-plan.md §7): what the
// simulator cannot show, because it does not enforce the sandbox.
//
// Debug builds only, and only with --dart-define=FPW_AUTOCHECK=true. On
// every launch it checks each picked directory, logging one `DEVICE` line
// per step:
// - identifiers saved by the previous launch: acquire and read them again;
// - a throwaway test tree inside the picked folder (created once, through
//   the acquired path with dart:io): trip.json, .howitwent, media/clip.mp4,
//   media/deep/, big/ with 10k files, and a symlink `out` -> `..`;
// - listChildren, lookupChild, readFile and writeFile on child and
//   grandchild identifiers; the 10k listing timed with its identifier
//   bytes; what the symlink does, through the plugin and through raw
//   dart:io (the sandbox's own answer).
// Nothing outside the picked folder is read: the dart:io probe through
// `out` logs only whether access was allowed and how many entries, never
// names.

// ignore_for_file: experimental_member_use

import 'dart:convert';
import 'dart:io';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _logger = Logger('device_checks');

const autoCheck = bool.fromEnvironment('FPW_AUTOCHECK');

/// With --dart-define=FPW_CLEANUP=true (and FPW_AUTOCHECK=true), the run
/// removes the test tree it created instead of checking.
const cleanUp = bool.fromEnvironment('FPW_CLEANUP');

/// Deletes exactly the fixture's own entries in the picked folder (the
/// `out` link itself, never its target) and the saved identifiers.
Future<void> removeDeviceFixture(FileInfo directory) async {
  final plugin = FilePickerWritable();
  final scope = await plugin.acquire(identifier: directory.identifier);
  try {
    final path = scope.path!;
    for (final name in ['trip.json', '.howitwent', 'fpw-fixture.txt']) {
      final file = File('$path/$name');
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
    final link = Link('$path/out');
    if (link.existsSync()) {
      link.deleteSync();
    }
    for (final name in ['media', 'big']) {
      final dir = Directory('$path/$name');
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
    _logger.info(
      'DEVICE fixture removed; ${directory.fileName} now holds '
      '${Directory(path).listSync().length} entries',
    );
  } finally {
    await plugin.release(scope);
  }
  final saved = File(
    '${(await getApplicationDocumentsDirectory()).path}/fpw_saved_ids.json',
  );
  if (saved.existsSync()) {
    saved.deleteSync();
  }
}

const _bigCount = 10000;

Future<void> runDeviceChecks(FileInfo directory) async {
  final plugin = FilePickerWritable();
  final root = directory.identifier;

  void log(String line) => _logger.info('DEVICE $line');

  Future<T?> step<T>(String label, Future<T> Function() run) async {
    try {
      final result = await run();
      log('$label: $result');
      return result;
    } on Exception catch (e) {
      log('$label: threw $e');
      return null;
    }
  }

  Future<DirectoryListing?> timedList(String label, String identifier) {
    return step('list $label', () async {
      final stopwatch = Stopwatch()..start();
      final listing = await plugin.listChildren(identifier: identifier);
      final ms = stopwatch.elapsedMilliseconds;
      final bytes = listing.entries.fold<int>(
        0,
        (sum, entry) => sum + entry.identifier.length,
      );
      log(
        'list $label: ${listing.entries.length} entries in $ms ms (Dart, end '
        'to end), ids $bytes bytes total, '
        '${listing.entries.isEmpty ? 0 : bytes ~/ listing.entries.length} each',
      );
      return listing;
    });
  }

  ChildEntry? named(DirectoryListing? listing, String name) {
    for (final entry in listing?.entries ?? const <ChildEntry>[]) {
      if (entry.name == name) {
        return entry;
      }
    }
    return null;
  }

  Future<String> read(String identifier) => plugin.readFile(
    identifier: identifier,
    reader: (info, file) async => '"${file.readAsStringSync()}"',
  );

  Future<String> write(String identifier, String content) async {
    await plugin.writeFile(
      identifier: identifier,
      writer: (file) => file.writeAsString(content),
    );
    return 'wrote "$content", reads back ${await read(identifier)}';
  }

  log('=== start for ${directory.fileName}');

  // 2. Identifiers saved by the previous launch.
  final saved = File(
    '${(await getApplicationDocumentsDirectory()).path}/fpw_saved_ids.json',
  );
  if (saved.existsSync()) {
    final ids = (jsonDecode(saved.readAsStringSync()) as Map)
        .cast<String, String>();
    for (final MapEntry(key: label, value: id) in ids.entries) {
      await step('relaunch acquire $label', () async {
        final scope = await plugin.acquire(identifier: id);
        await plugin.release(scope);
        return 'repaired: ${scope.repaired}, name: ${scope.displayName}';
      });
      if (!label.endsWith('/')) {
        await step('relaunch readFile $label', () => read(id));
      }
    }
  } else {
    log('no identifiers saved by a previous launch');
  }

  await _ensureFixture(plugin, root, log);

  // 1. The tree, through the plugin, in this fresh launch.
  final listing = await timedList('root', root);
  await step(
    'lookup .howitwent',
    () => plugin.lookupChild(identifier: root, name: '.howitwent'),
  );
  await step(
    'lookup missing.txt',
    () => plugin.lookupChild(identifier: root, name: 'missing.txt'),
  );
  final trip = named(listing, 'trip.json');
  final media = named(listing, 'media');
  if (trip != null) {
    await step('readFile child trip.json', () => read(trip.identifier));
    await step(
      'writeFile child trip.json',
      () => write(trip.identifier, '{"written":"${DateTime.now()}"}'),
    );
  }
  ChildEntry? clip;
  if (media != null) {
    final mediaListing = await timedList('child media', media.identifier);
    clip = named(mediaListing, 'clip.mp4');
    final deep = named(mediaListing, 'deep');
    if (clip != null) {
      final grandchild = clip.identifier;
      await step('readFile grandchild clip.mp4', () => read(grandchild));
      await step(
        'writeFile grandchild clip.mp4',
        () => write(grandchild, 'clip ${DateTime.now()}'),
      );
      await step(
        'lookup grandchild clip.mp4',
        () =>
            plugin.lookupChild(identifier: media.identifier, name: 'clip.mp4'),
      );
    }
    if (deep != null) {
      await timedList('grandchild deep', deep.identifier);
    }
  }

  // 3. 10k children, three runs.
  final big = named(listing, 'big');
  if (big != null) {
    for (var run = 1; run <= 3; run++) {
      await timedList('big run $run', big.identifier);
    }
  }

  // 4. The symlink out of the root, through the plugin.
  final out = named(listing, 'out');
  log('out in root listing: $out');
  if (out != null) {
    await timedList('symlink out', out.identifier);
    await step(
      'lookup through symlink out',
      () => plugin.lookupChild(identifier: out.identifier, name: 'x'),
    );
    await step('readFile symlink out', () => read(out.identifier));
  }

  // Saved for the next launch's relaunch checks.
  saved.writeAsStringSync(
    jsonEncode({
      if (trip != null) ...{'child trip.json': trip.identifier},
      if (clip != null) ...{'grandchild clip.mp4': clip.identifier},
      if (media != null) ...{'child media/': media.identifier},
    }),
  );
  log('=== done; saved ${saved.path}');
}

/// Creates the throwaway test tree once, under the acquired scope, and
/// probes the symlink with raw dart:io (the sandbox's answer, before the
/// plugin's containment check is involved).
Future<void> _ensureFixture(
  FilePickerWritable plugin,
  String root,
  void Function(String) log,
) async {
  final scope = await plugin.acquire(identifier: root);
  try {
    final path = scope.path!;
    final marker = File('$path/fpw-fixture.txt');
    if (!marker.existsSync()) {
      final stopwatch = Stopwatch()..start();
      File('$path/trip.json').writeAsStringSync('{}');
      File('$path/.howitwent').writeAsStringSync('x');
      Directory('$path/media/deep').createSync(recursive: true);
      File('$path/media/clip.mp4').writeAsStringSync('clip');
      final big = Directory('$path/big')..createSync();
      for (var i = 0; i < _bigCount; i++) {
        File('${big.path}/f$i.jpg').createSync();
      }
      Link('$path/out').createSync('..');
      marker.writeAsStringSync('file_picker_writable device-run fixture');
      log('fixture created in ${stopwatch.elapsedMilliseconds} ms');
    } else {
      log('fixture present');
    }
    // The sandbox's own answer for the symlink: counts only, no names.
    try {
      final entries = Directory('$path/out').listSync();
      log('dart:io through out: ALLOWED, ${entries.length} entries');
    } on FileSystemException catch (e) {
      log('dart:io through out: refused (${e.osError})');
    }
  } finally {
    await plugin.release(scope);
  }
}
