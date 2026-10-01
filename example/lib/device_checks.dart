// The device run for #69 (doc/tree-traversal-plan.md §7): what the
// simulator cannot show, because it does not enforce the sandbox.
//
// Debug builds only (kDebugMode), and only with
// --dart-define=FPW_AUTOCHECK=true. On every launch it checks each picked
// directory, logging one `DEVICE` line per step:
// - identifiers saved by the previous launch: acquire and read them again;
// - a throwaway test tree in its own `fpw-device-fixture/` folder inside
//   the picked folder (created once, through the acquired path with
//   dart:io), with names no app would take for its own data:
//   probe.json, .fpw-probe, nested/leaf.bin, nested/deeper/, many/ with
//   10k files, and a symlink `out` -> `../..` (out of the picked folder);
// - listChildren, lookupChild, readFile and writeFile on child and
//   grandchild identifiers of that folder; the 10k listing timed; what the
//   symlink does, through the plugin and through raw dart:io (the
//   sandbox's own answer).
// Nothing outside the picked folder is read: the dart:io probe through
// `out` logs only whether access was allowed and how many entries, never
// names. FPW_CLEANUP=true removes the fixture folder again.

// ignore_for_file: experimental_member_use

import 'dart:convert';
import 'dart:io';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _logger = Logger('device_checks');

/// The device run is debug-only: a release or profile build ignores the
/// define.
const autoCheck = kDebugMode && bool.fromEnvironment('FPW_AUTOCHECK');

/// With --dart-define=FPW_CLEANUP=true (and FPW_AUTOCHECK=true), the run
/// removes the test tree it created instead of checking.
const cleanUp = bool.fromEnvironment('FPW_CLEANUP');

const _fixtureName = 'fpw-device-fixture';

const _manyCount = 10000;

Future<File> _savedIds() async => File(
  '${(await getApplicationDocumentsDirectory()).path}/fpw_saved_ids.json',
);

/// Deletes the fixture folder (a recursive delete removes the `out` link
/// itself, never its target) and the saved identifiers.
Future<void> removeDeviceFixture(FileInfo directory) async {
  final plugin = FilePickerWritable();
  final scope = await plugin.acquire(identifier: directory.identifier);
  try {
    final fixture = Directory('${scope.path!}/$_fixtureName');
    if (fixture.existsSync()) {
      fixture.deleteSync(recursive: true);
    }
    _logger.info(
      'DEVICE fixture removed; ${directory.fileName} now holds '
      '${Directory(scope.path!).listSync().length} entries',
    );
  } finally {
    await plugin.release(scope);
  }
  final saved = await _savedIds();
  if (saved.existsSync()) {
    saved.deleteSync();
  }
}

Future<void> runDeviceChecks(FileInfo directory) async {
  final plugin = FilePickerWritable();

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
      // The composed length, as if every identifier were held at once.
      // What crosses the channel is the native log's "identifier bytes"
      // (the shared prefix once, plus the suffixes).
      final bytes = listing.entries.fold<int>(
        0,
        (sum, entry) => sum + entry.identifier.length,
      );
      log(
        'list $label: ${listing.entries.length} entries in $ms ms (Dart, end '
        'to end), composed ids $bytes bytes if all held, '
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
  final saved = await _savedIds();
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

  await _ensureFixture(plugin, directory.identifier, log);
  final fixtureEntry = await plugin.lookupChild(
    identifier: directory.identifier,
    name: _fixtureName,
  );
  if (fixtureEntry == null) {
    log('=== no fixture folder found; stopping');
    return;
  }
  final root = fixtureEntry.identifier;

  // 1. The tree, through the plugin, in this fresh launch.
  final listing = await timedList('fixture', root);
  await step(
    'lookup .fpw-probe',
    () => plugin.lookupChild(identifier: root, name: '.fpw-probe'),
  );
  await step(
    'lookup missing.txt',
    () => plugin.lookupChild(identifier: root, name: 'missing.txt'),
  );
  final probe = named(listing, 'probe.json');
  final nested = named(listing, 'nested');
  if (probe != null) {
    await step('readFile child probe.json', () => read(probe.identifier));
    await step(
      'writeFile child probe.json',
      () => write(probe.identifier, '{"written":"${DateTime.now()}"}'),
    );
  }
  ChildEntry? leaf;
  if (nested != null) {
    final nestedListing = await timedList('child nested', nested.identifier);
    leaf = named(nestedListing, 'leaf.bin');
    final deeper = named(nestedListing, 'deeper');
    if (leaf != null) {
      final grandchild = leaf.identifier;
      await step('readFile grandchild leaf.bin', () => read(grandchild));
      await step(
        'writeFile grandchild leaf.bin',
        () => write(grandchild, 'leaf ${DateTime.now()}'),
      );
      await step(
        'lookup grandchild leaf.bin',
        () =>
            plugin.lookupChild(identifier: nested.identifier, name: 'leaf.bin'),
      );
    }
    if (deeper != null) {
      await timedList('grandchild deeper', deeper.identifier);
    }
  }

  // 3. 10k children, three runs.
  final many = named(listing, 'many');
  if (many != null) {
    for (var run = 1; run <= 3; run++) {
      await timedList('many run $run', many.identifier);
    }
  }

  // 4. The symlink out of the picked folder, through the plugin.
  final out = named(listing, 'out');
  log('out in fixture listing: $out');
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
      if (probe != null) ...{'child probe.json': probe.identifier},
      if (leaf != null) ...{'grandchild leaf.bin': leaf.identifier},
      if (nested != null) ...{'child nested/': nested.identifier},
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
    final path = '${scope.path!}/$_fixtureName';
    final marker = File('$path/fpw-fixture.txt');
    if (!marker.existsSync()) {
      final stopwatch = Stopwatch()..start();
      Directory('$path/nested/deeper').createSync(recursive: true);
      File('$path/probe.json').writeAsStringSync('{}');
      File('$path/.fpw-probe').writeAsStringSync('x');
      File('$path/nested/leaf.bin').writeAsStringSync('leaf');
      final many = Directory('$path/many')..createSync();
      for (var i = 0; i < _manyCount; i++) {
        File('${many.path}/f$i.bin').createSync();
      }
      // Two levels up: out of the fixture folder AND the picked folder.
      Link('$path/out').createSync('../..');
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
