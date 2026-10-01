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
//   sandbox's own answer);
// - large-file reads (Gap 2b's openRead and FdReader) on a 32 MiB big.bin in
//   the same folder: spot reads, a helper isolate reading it all, the
//   error cases, and the open-descriptor count before and after;
// - tree verbs (createDirectory, deleteEntry, moveEntry) in a `tree/`
//   folder of the fixture, rebuilt every run, and with two or more picks
//   a probe folder moved from the first pick to the second and back.
// Nothing outside the picked folder is read: the dart:io probe through
// `out` logs only whether access was allowed and how many entries, never
// names. FPW_CLEANUP=true removes the fixture folder again.

// ignore_for_file: experimental_member_use

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

const _bigName = 'big.bin';

/// 32 MiB and an odd tail: many 1 MiB chunks, the last one short.
const _bigLength = (32 << 20) + 1234;

/// big.bin's byte at [offset]. Position-dependent, so a chunk read from the
/// wrong offset does not match.
int _bigByte(int offset) => (offset * 7 + (offset >> 12)) & 0xff;

/// How many bytes of [view], read at [offset], differ from big.bin.
int _mismatches(Uint8List view, int offset) {
  var count = 0;
  for (var i = 0; i < view.length; i++) {
    if (view[i] != _bigByte(offset + i)) {
      count++;
    }
  }
  return count;
}

/// Reads the whole handed-off file in a helper isolate, 1 MiB per chunk:
/// the byte count, the microseconds the reads took (timed inside the
/// helper, so the spawn is not in it) and, with [verify], how many bytes
/// differ from big.bin. A factory, so the closure captures the record and
/// nothing else.
(int, int, int) Function() _readAll(
  ReadHandoff handoff, {
  required bool verify,
}) => () {
  final stopwatch = Stopwatch()..start();
  final reader = FdReader.fromHandoff(handoff);
  try {
    var position = 0;
    var mismatches = 0;
    while (true) {
      final chunk = reader.readChunk(position, reader.bufferLength);
      if (chunk.isEmpty) {
        return (position, stopwatch.elapsedMicroseconds, mismatches);
      }
      if (verify) {
        mismatches += _mismatches(chunk, position);
      }
      position += chunk.length;
    }
  } finally {
    reader.close();
  }
};

/// Open descriptors of this process, or null where it cannot tell.
int? _openFds() {
  for (final path in ['/proc/self/fd', '/dev/fd']) {
    try {
      return Directory(path).listSync().length;
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

Future<File> _savedIds() async => File(
  '${(await getApplicationDocumentsDirectory()).path}/fpw_saved_ids.json',
);

/// Deletes the fixture folder and the saved identifiers. The folder holds
/// `out -> ../..`, so this relies, deliberately, on dart:io's recursive
/// delete removing a symlink itself and never following it: a delete that
/// followed links would remove the user's folders above the pick.
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

  // 5. Large-file reads (doc/large-file-reads-plan.md §7).
  final big = named(listing, _bigName);
  if (big == null) {
    log('no $_bigName in the fixture; skipping the read checks');
  } else {
    await _readChecks(plugin, big, nested, step, log);
  }

  // 6. Tree verbs (doc/tree-writes-plan.md §7), in fixture/tree.
  await _treeChecks(plugin, directory, root, step, log);

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

/// A move between two picked folders: a probe folder created in [first]
/// is moved into [second] and back. Across storage volumes (an internal
/// folder and a stick) that is `unsupported-move` and nothing moves; on
/// one volume it is an ordinary move between two picks.
Future<void> runCrossPickChecks(FileInfo first, FileInfo second) async {
  const probeName = 'fpw-move-probe';
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

  log('=== cross-pick: ${first.fileName} -> ${second.fileName}');
  final from = await plugin.acquire(identifier: first.identifier);
  final to = await plugin.acquire(identifier: second.identifier);
  try {
    for (final pick in [first, second]) {
      final old = await plugin.lookupChild(
        identifier: pick.identifier,
        name: probeName,
      );
      if (old != null) {
        await plugin.deleteEntry(identifier: old.identifier, recursive: true);
      }
    }
    final probe = await step(
      'cross: createDirectory $probeName in ${first.fileName}',
      () => plugin.createDirectory(scope: from, name: probeName),
    );
    if (probe == null) {
      return;
    }
    final moved = await step(
      'cross: move it into ${second.fileName}',
      () => plugin.moveEntry(
        identifier: probe.identifier,
        sourceParent: from,
        newParent: to,
      ),
    );
    Future<String> whereIsIt() async {
      final inFirst = await plugin.lookupChild(
        identifier: first.identifier,
        name: probeName,
      );
      final inSecond = await plugin.lookupChild(
        identifier: second.identifier,
        name: probeName,
      );
      return 'in ${first.fileName}: ${inFirst != null}, '
          'in ${second.fileName}: ${inSecond != null}';
    }

    await step('cross: after the move', whereIsIt);
    if (moved != null) {
      await step(
        'cross: move it back',
        () => plugin.moveEntry(
          identifier: moved.identifier,
          sourceParent: to,
          newParent: from,
        ),
      );
      await step('cross: after the move back', whereIsIt);
    }
    // Clean up wherever it ended.
    for (final pick in [first, second]) {
      final left = await plugin.lookupChild(
        identifier: pick.identifier,
        name: probeName,
      );
      if (left != null) {
        await step(
          'cross: delete the probe in ${pick.fileName}',
          () => plugin
              .deleteEntry(identifier: left.identifier, recursive: true)
              .then((_) => 'ok'),
        );
      }
    }
  } finally {
    await plugin.release(from);
    await plugin.release(to);
  }
  log('=== cross-pick done');
}

/// createDirectory, deleteEntry and moveEntry in a `tree/` folder of the
/// fixture [root], rebuilt on every run: taken names, provider-cleaned
/// names, the residue that must not be left behind, renames, a move with a
/// rename, the non-recursive refusal, recursion, idempotent delete, and
/// the picked root's protection. Every expected failure is logged as
/// "threw", so the log reads as the matrix.
Future<void> _treeChecks(
  FilePickerWritable plugin,
  FileInfo picked,
  String root,
  Future<T?> Function<T>(String label, Future<T> Function() run) step,
  void Function(String) log,
) async {
  Future<String> names(String identifier) async {
    final listing = await plugin.listChildren(identifier: identifier);
    return (listing.entries.map((e) => e.name).toList()..sort()).join(', ');
  }

  Future<String> ok(Future<void> run) => run.then((_) => 'ok');

  final fixture = await plugin.acquire(identifier: root);
  try {
    final old = await plugin.lookupChild(identifier: root, name: 'tree');
    if (old != null) {
      await step(
        'tree: delete the last run',
        () =>
            ok(plugin.deleteEntry(identifier: old.identifier, recursive: true)),
      );
    }
    final tree = await step(
      'tree: createDirectory tree',
      () => plugin.createDirectory(scope: fixture, name: 'tree'),
    );
    if (tree == null) {
      return;
    }
    await step(
      'tree: createDirectory tree again (taken)',
      () => plugin.createDirectory(scope: fixture, name: 'tree'),
    );
    final treeScope = await plugin.acquire(identifier: tree.identifier);
    try {
      // A file there and back: a move with a rename each way.
      final probe = await plugin.lookupChild(
        identifier: root,
        name: 'probe.json',
      );
      if (probe != null) {
        final moved = await step(
          'tree: move probe.json into tree, renamed p.json',
          () => plugin.moveEntry(
            identifier: probe.identifier,
            sourceParent: fixture,
            newParent: treeScope,
            newName: 'p.json',
          ),
        );
        if (moved != null) {
          await step(
            'tree: move p.json back as probe.json',
            () => plugin.moveEntry(
              identifier: moved.identifier,
              sourceParent: treeScope,
              newParent: fixture,
              newName: 'probe.json',
            ),
          );
        }
      }
      final a = await step(
        'tree: createDirectory a',
        () => plugin.createDirectory(scope: treeScope, name: 'a'),
      );
      final b = await step(
        'tree: createDirectory b',
        () => plugin.createDirectory(scope: treeScope, name: 'b'),
      );
      await step(
        'tree: createDirectory "12:30 ride" (FAT-style name)',
        () => plugin.createDirectory(scope: treeScope, name: '12:30 ride'),
      );
      await step(
        'tree: listing after the creates',
        () => names(tree.identifier),
      );
      if (a == null || b == null) {
        return;
      }
      final aScope = await plugin.acquire(identifier: a.identifier);
      try {
        await step(
          'tree: createDirectory a/inner',
          () => plugin.createDirectory(scope: aScope, name: 'inner'),
        );
        await step(
          'tree: delete a, not recursive (holds inner)',
          () => ok(plugin.deleteEntry(identifier: a.identifier)),
        );
        final c = await step(
          'tree: rename b to c',
          () => plugin.moveEntry(
            identifier: b.identifier,
            sourceParent: treeScope,
            newParent: treeScope,
            newName: 'c',
          ),
        );
        await step(
          'tree: rename a onto c (taken)',
          () => plugin.moveEntry(
            identifier: a.identifier,
            sourceParent: treeScope,
            newParent: treeScope,
            newName: 'c',
          ),
        );
        if (c != null) {
          await step(
            'tree: rename c to "x:y" (FAT-style name)',
            () => plugin.moveEntry(
              identifier: c.identifier,
              sourceParent: treeScope,
              newParent: treeScope,
              newName: 'x:y',
            ),
          );
          await step(
            'tree: listing after the renames',
            () => names(tree.identifier),
          );
          // A rename that landed on iOS moved c; find it again by listing.
          final listing = await plugin.listChildren(
            identifier: tree.identifier,
          );
          final current = listing.entries
              .where((e) => e.name == 'c' || e.name == 'x:y')
              .firstOrNull;
          if (current != null) {
            await step(
              'tree: move ${current.name} into a, renamed d',
              () => plugin.moveEntry(
                identifier: current.identifier,
                sourceParent: treeScope,
                newParent: aScope,
                newName: 'd',
              ),
            );
          }
        }
        await step('tree: listing of a', () => names(a.identifier));
        final inner = await plugin.lookupChild(
          identifier: a.identifier,
          name: 'inner',
        );
        if (inner != null) {
          await step(
            'tree: move inner with the wrong source parent',
            () => plugin.moveEntry(
              identifier: inner.identifier,
              sourceParent: treeScope,
              newParent: treeScope,
            ),
          );
        }
      } finally {
        await plugin.release(aScope);
      }
      await step(
        'tree: delete a, recursive',
        () => ok(plugin.deleteEntry(identifier: a.identifier, recursive: true)),
      );
      await step(
        'tree: delete a again (gone is success)',
        () => ok(plugin.deleteEntry(identifier: a.identifier, recursive: true)),
      );
      await step('tree: final listing', () => names(tree.identifier));
    } finally {
      await plugin.release(treeScope);
    }
    // Not recursive on purpose: should the guard ever break, the picked
    // folder still holds the fixture, so this is directory-not-empty, not
    // a deleted pick.
    await step(
      'tree: delete the picked root (protected)',
      () => ok(plugin.deleteEntry(identifier: picked.identifier)),
    );
    // Android: other spellings of the root's document ID, which the
    // provider may resolve to the root itself. Not recursive, for the same
    // reason as above.
    const treeMarker = '/tree/';
    final at = picked.identifier.indexOf(treeMarker);
    if (picked.identifier.startsWith('content://') && at >= 0) {
      final encodedTree = picked.identifier.substring(at + treeMarker.length);
      final treeId = Uri.decodeComponent(encodedTree);
      for (final spelling in [
        '$treeId/',
        '$treeId/.',
        treeId.toLowerCase() == treeId
            ? treeId.toUpperCase()
            : treeId.toLowerCase(),
      ]) {
        final variant =
            '${picked.identifier}/document/${Uri.encodeComponent(spelling)}';
        await step(
          'tree: delete the picked root spelled "$spelling" (protected)',
          () => ok(plugin.deleteEntry(identifier: variant)),
        );
      }
    }
    await step(
      'tree: delete tree, recursive',
      () =>
          ok(plugin.deleteEntry(identifier: tree.identifier, recursive: true)),
    );
  } finally {
    await plugin.release(fixture);
  }
}

/// openRead on big.bin: spot reads on this isolate, a helper reading it all
/// (verified, then timed), the error cases, and the process's descriptor
/// count before and after (every path must close what it opened).
Future<void> _readChecks(
  FilePickerWritable plugin,
  ChildEntry big,
  ChildEntry? directory,
  Future<T?> Function<T>(String label, Future<T> Function() run) step,
  void Function(String) log,
) async {
  final fdsBefore = _openFds();
  final scope = await plugin.acquire(identifier: big.identifier);
  try {
    await step('read spot checks', () async {
      final session = await plugin.openRead(scope: scope);
      final reader = FdReader.fromSession(session);
      try {
        const middle = 4 << 20;
        const tail = _bigLength - 10;
        final atMiddle = _mismatches(reader.readChunk(middle, 1024), middle);
        final atTail = reader.readChunk(tail, 1024);
        final tailLength = atTail.length;
        final tailMismatches = _mismatches(atTail, tail);
        final pastEnd = reader.readChunk(_bigLength + 5, 16).length;
        return 'seekable ${session.seekable}, length ${session.length} '
            '(expected $_bigLength), middle $atMiddle mismatches, tail '
            '$tailLength bytes with $tailMismatches mismatches, past the end '
            '$pastEnd bytes';
      } finally {
        reader.close();
      }
    });
    for (final verify in [true, false, false]) {
      await step(
        'read all in a helper (${verify ? 'verified' : 'timed'})',
        () async {
          final session = await plugin.openRead(scope: scope);
          // Handed off before the spawn: if handoff throws, the session is
          // still ours to close.
          final ReadHandoff record;
          try {
            record = session.handoff();
          } on Exception {
            await plugin.closeRead(session);
            rethrow;
          }
          final (bytes, micros, mismatches) = await Isolate.run(
            _readAll(record, verify: verify),
          );
          final mibs = micros == 0
              ? 'n/a'
              : (bytes / (1 << 20) / (micros / 1e6)).toStringAsFixed(0);
          return '$bytes bytes in ${micros ~/ 1000} ms in the helper '
              '($mibs MiB/s)${verify ? ', $mismatches mismatches' : ''}';
        },
      );
    }
    await step('closeRead twice', () async {
      final session = await plugin.openRead(scope: scope);
      await plugin.closeRead(session);
      await plugin.closeRead(session);
      return 'ok';
    });
  } finally {
    await plugin.release(scope);
  }
  await step('openRead after release', () => plugin.openRead(scope: scope));
  await step('reader close after release', () async {
    final scope = await plugin.acquire(identifier: big.identifier);
    final reader = FdReader.fromSession(await plugin.openRead(scope: scope));
    reader.readChunk(0, 16);
    await plugin.release(scope);
    reader.close();
    return 'closed without scope-closed';
  });
  if (directory != null) {
    await step('openRead on a directory', () async {
      final scope = await plugin.acquire(identifier: directory.identifier);
      try {
        final session = await plugin.openRead(scope: scope);
        await plugin.closeRead(session);
        return 'opened';
      } finally {
        await plugin.release(scope);
      }
    });
  }
  log('read checks: open descriptors $fdsBefore before, ${_openFds()} after');
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
    final base = scope.path;
    if (base == null) {
      // Android: no path to create it through. Push the same tree with adb
      // (big.bin from the formula in _bigByte).
      log('no path here; expecting an adb-pushed fixture');
      return;
    }
    final path = '$base/$_fixtureName';
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
    // Its own check, so a fixture from before the read checks gets it too.
    final big = File('$path/$_bigName');
    if (!big.existsSync() || big.lengthSync() != _bigLength) {
      final file = big.openSync(mode: FileMode.write);
      try {
        final chunk = Uint8List(1 << 20);
        for (var offset = 0; offset < _bigLength; offset += chunk.length) {
          final length = _bigLength - offset < chunk.length
              ? _bigLength - offset
              : chunk.length;
          for (var i = 0; i < length; i++) {
            chunk[i] = _bigByte(offset + i);
          }
          file.writeFromSync(chunk, 0, length);
        }
      } finally {
        file.closeSync();
      }
      log('$_bigName created');
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
