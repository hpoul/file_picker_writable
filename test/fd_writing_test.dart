// FFI tests for the write half (Gap 3 write sessions,
// doc/tree-writes-plan.md §7): real descriptors and the real shim, with
// only the control calls faked (openWrite creates a real temp file,
// statEntry stats it, deleteEntry deletes it). They prove the Dart side:
// acknowledged totals, staging past the buffer, commit and abort and their
// idempotency, the single-owner rules, the kill path's identifier-only
// abort, pipes, error mapping and the root-isolate budget. A helper's own
// channel calls (commit or abort from the helper) need a real engine: the
// device run proves those.

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_picker_writable/src/fd_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _libc = DynamicLibrary.process();
final _malloc = _libc
    .lookupFunction<
      Pointer<Uint8> Function(IntPtr),
      Pointer<Uint8> Function(int)
    >('malloc');
final _free = _libc
    .lookupFunction<
      Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)
    >('free');
final _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Uint8>, Int32, VarArgs<(Int32,)>),
      int Function(Pointer<Uint8>, int, int)
    >('open');
final _pipe = _libc
    .lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)
    >('pipe');
final _read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _fcntl = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');

/// True when [fd] is not open (F_GETFD only asks).
bool isClosed(int fd) => _fcntl(fd, 1 /* F_GETFD */, 0) == -1;

/// Opens [path] with [flags] (mode 0644 on create) through libc.
int openPath(String path, int flags) {
  final bytes = Uint8List.fromList([...path.codeUnits, 0]);
  final native = _malloc(bytes.length);
  native.asTypedList(bytes.length).setAll(0, bytes);
  try {
    final fd = _open(native, flags, 420 /* 0644 */);
    expect(fd, greaterThanOrEqualTo(0), reason: 'open $path');
    return fd;
  } finally {
    _free(native);
  }
}

// Darwin and Linux differ here; the tests run on the host.
final _oWronly = 1;
final _oCreatExcl = Platform.isMacOS ? 0x200 | 0x800 : 0x40 | 0x80;

/// Reads everything left in the pipe [fd] (its write end closed).
List<int> drain(int fd) {
  final buffer = _malloc(4096);
  final out = <int>[];
  try {
    while (true) {
      final n = _read(fd, buffer, 4096);
      if (n <= 0) {
        return out;
      }
      out.addAll(buffer.asTypedList(n));
    }
  } finally {
    _free(buffer);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('design.codeux.file_picker_writable');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final plugin = FilePickerWritable();

  late Directory dir;
  late List<MethodCall> calls;
  late Map<String, Object?> Function(String name) nextOpen;
  var token = 0;

  Map<String, Object?> entryFor(String path) => {
    'name': path.split('/').last,
    'identifier': path,
    'isDirectory': false,
    'size': File(path).lengthSync(),
    'lastModified': File(path).lastModifiedSync().millisecondsSinceEpoch,
  };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fpw-write-');
    calls = [];
    nextOpen = (name) {
      final path = '${dir.path}/$name';
      return {
        'fd': openPath(path, _oWronly | _oCreatExcl),
        'identifier': path,
        'canFsync': true,
      };
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = (call.arguments as Map?)?.cast<String, Object?>();
      switch (call.method) {
        case 'acquire':
          return {
            'id': 'scope-${token++}',
            'identifier': dir.path,
            'repaired': false,
            'path': dir.path,
            'displayName': 'dir',
          };
        case 'openWrite':
          return nextOpen(args!['name']! as String);
        case 'statEntry':
          final path = args!['identifier']! as String;
          return File(path).existsSync() ? entryFor(path) : null;
        case 'abortPartial':
          final file = File(args!['identifier']! as String);
          if (file.existsSync()) {
            file.deleteSync();
          }
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    dir.deleteSync(recursive: true);
  });

  Future<(AcquiredScope, WriteSession)> open(String name) async {
    final scope = await plugin.acquire(identifier: 'dir');
    return (scope, await plugin.openWrite(scope: scope, name: name));
  }

  Matcher kind(String code) =>
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', code));

  final bytes = Uint8List.fromList(List.generate(100, (i) => i * 7 % 256));

  group('openWrite', () {
    test('sends scope, name and MIME type; reports the session', () async {
      final (scope, session) = await open('clip.mp4.writing');
      final sent = calls.firstWhere((c) => c.method == 'openWrite');
      expect(sent.arguments, {
        'scope': scope.id,
        'name': 'clip.mp4.writing',
        'mimeType': 'application/octet-stream',
      });
      expect(session.identifier, '${dir.path}/clip.mp4.writing');
      expect(session.canFsync, isTrue);
      expect(session.bytesWritten, 0);
      await plugin.abortWrite(session);
      await plugin.release(scope);
    });

    test('a released scope and a bad name fail before any call', () async {
      final scope = await plugin.acquire(identifier: 'dir');
      await expectLater(
        plugin.openWrite(scope: scope, name: 'a/b'),
        throwsArgumentError,
      );
      await plugin.release(scope);
      await expectLater(
        plugin.openWrite(scope: scope, name: 'x'),
        kind('scope-closed'),
      );
      expect(calls.where((c) => c.method == 'openWrite'), isEmpty);
    });
  });

  group('FdWriter on the same isolate', () {
    test('totals, staging past the buffer, commit', () async {
      final (scope, session) = await open('a.bin');
      final writer = FdWriter.fromSession(session, bufferLength: 16);
      expect(writer.writeChunk(bytes.sublist(0, 10)), 10);
      expect(writer.writeChunk(bytes.sublist(10)), 100);
      expect(session.bytesWritten, 100);
      final entry = await writer.closeWrite();
      expect(entry.name, 'a.bin');
      expect(entry.size, 100);
      expect(File(session.identifier).readAsBytesSync(), bytes);
      expect(isClosed(session.fd), isTrue);
      // Idempotent: the same entry, no second stat.
      final stats = calls.where((c) => c.method == 'statEntry').length;
      expect(await writer.closeWrite(), same(entry));
      expect(calls.where((c) => c.method == 'statEntry').length, stats);
      expect(() => writer.writeChunk(bytes), kind('session-closed'));
      await expectLater(writer.abort(), throwsStateError);
      await plugin.release(scope);
    });

    test('abort deletes the partial, idempotently', () async {
      final (scope, session) = await open('b.bin');
      final writer = FdWriter.fromSession(session)..writeChunk(bytes);
      await writer.abort();
      expect(File(session.identifier).existsSync(), isFalse);
      expect(isClosed(session.fd), isTrue);
      await writer.abort();
      await expectLater(writer.closeWrite(), kind('session-closed'));
      await plugin.release(scope);
    });

    test('a scope released mid-write does not fail the commit', () async {
      final (scope, session) = await open('c.bin');
      final writer = FdWriter.fromSession(session)..writeChunk(bytes);
      await plugin.release(scope);
      // The bytes are down: throwing here would invite an abort of a good
      // file.
      expect((await writer.closeWrite()).size, 100);
      expect(isClosed(session.fd), isTrue);
    });

    test('a file someone else wrote to is size-mismatch, kept', () async {
      final (scope, session) = await open('m.bin');
      final writer = FdWriter.fromSession(session)..writeChunk(bytes);
      File(
        session.identifier,
      ).writeAsBytesSync(List.filled(50, 1), mode: FileMode.append);
      await expectLater(
        writer.closeWrite(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'size-mismatch')
              .having((e) => (e.details as Map)['size'], 'size', 150),
        ),
      );
      expect(File(session.identifier).lengthSync(), 150);
      // Someone else's bytes are in it: no abort deletes it.
      await expectLater(writer.abort(), throwsStateError);
      expect(File(session.identifier).existsSync(), isTrue);
      await plugin.release(scope);
    });

    test('abort sends what proves the file is still the session’s', () async {
      nextOpen = (name) {
        final path = '${dir.path}/$name';
        return {
          'fd': openPath(path, _oWronly | _oCreatExcl),
          'identifier': path,
          'canFsync': true,
          'fileId': '1:42',
        };
      };
      final before = DateTime.now().millisecondsSinceEpoch;
      final (scope, session) = await open('p.bin');
      final writer = FdWriter.fromSession(session)..writeChunk(bytes);
      await writer.abort();
      final sent = calls.lastWhere((c) => c.method == 'abortPartial');
      final args = (sent.arguments as Map).cast<String, Object?>();
      expect(args['identifier'], session.identifier);
      expect(args['fileId'], '1:42');
      expect(args['bytesWritten'], 100);
      expect(args['openedAt'] as int, greaterThanOrEqualTo(before));
      await plugin.release(scope);
    });

    test('errno maps as for reads: a read-only descriptor is EBADF', () async {
      final path = '${dir.path}/ro.bin';
      File(path).writeAsBytesSync([1]);
      nextOpen = (_) => {
        'fd': openPath(path, 0 /* O_RDONLY */),
        'identifier': path,
        'canFsync': true,
      };
      final (scope, session) = await open('ro.bin');
      final writer = FdWriter.fromSession(session);
      expect(
        () => writer.writeChunk(bytes),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'session-closed')
              .having((e) => (e.details as Map)['code'], 'errno', 9),
        ),
      );
      await writer.abort();
      await plugin.release(scope);
    });

    test('one writer per session; none after handoff', () async {
      final (scope, session) = await open('d.bin');
      final writer = FdWriter.fromSession(session);
      expect(() => FdWriter.fromSession(session), throwsStateError);
      expect(session.handoff, throwsStateError);
      await writer.abort();
      await plugin.release(scope);
    });

    test('more than 1 MiB on the root isolate asserts', () async {
      final (scope, session) = await open('e.bin');
      final writer = FdWriter.fromSession(session);
      writer.writeChunk(Uint8List(1 << 20));
      expect(
        () => writer.writeChunk(Uint8List(1)),
        throwsA(isA<AssertionError>()),
      );
      await writer.abort();
      await plugin.release(scope);
    });
  });

  group('session-level verbs (no writer)', () {
    test('closeWrite commits a session nobody wrapped', () async {
      final (scope, session) = await open('f.bin');
      final entry = await plugin.closeWrite(session, fsync: false);
      expect(entry.size, 0);
      expect(isClosed(session.fd), isTrue);
      await expectLater(plugin.closeWrite(session), kind('session-closed'));
      await plugin.release(scope);
    });

    test('abortWrite closes and deletes; again is fine', () async {
      final (scope, session) = await open('g.bin');
      await plugin.abortWrite(session);
      expect(isClosed(session.fd), isTrue);
      expect(File(session.identifier).existsSync(), isFalse);
      await plugin.abortWrite(session);
      await plugin.release(scope);
    });
  });

  group('handoff', () {
    test('the dead copy refuses fd use but may abort by identifier', () async {
      final (scope, session) = await open('h.bin');
      final record = session.handoff();
      expect(() => FdWriter.fromSession(session), throwsStateError);
      await expectLater(plugin.closeWrite(session), throwsStateError);
      await expectLater(plugin.abortWrite(session), throwsStateError);
      // Recovery after a failed spawn: the root writes and commits itself.
      final writer = FdWriter.fromHandoff(record)..writeChunk(bytes);
      expect((await writer.closeWrite()).size, 100);
      await plugin.release(scope);
    });

    test('kill: the finalizer closes; the abort keeps the partial', () async {
      final (scope, session) = await open('k.bin');
      final record = session.handoff();
      final ready = ReceivePort();
      final exited = ReceivePort();
      final helper = await Isolate.spawn(_writeAndWait, (
        record,
        ready.sendPort,
      ), onExit: exited.sendPort);
      expect(await ready.first, 100);
      helper.kill(priority: Isolate.immediate);
      await exited.first;
      expect(isClosed(record.fd), isTrue, reason: 'closed by the finalizer');
      expect(File(session.identifier).lengthSync(), 100, reason: 'the partial');
      // The root's copy cannot know what the helper wrote, so nothing can
      // prove the file is still the partial: no delete, no native call.
      await plugin.abortWrite(session, closeFd: false);
      expect(calls.where((c) => c.method == 'abortPartial'), isEmpty);
      expect(File(session.identifier).lengthSync(), 100, reason: 'kept');
      await plugin.release(scope);
    });

    test('closeFd: false on a session that owns its fd is refused', () async {
      final (scope, session) = await open('l.bin');
      await expectLater(
        plugin.abortWrite(session, closeFd: false),
        throwsStateError,
      );
      expect(isClosed(session.fd), isFalse);
      await plugin.abortWrite(session);
      await plugin.release(scope);
    });
  });

  group('pipes', () {
    test('a full non-blocking pipe is waited on, every byte counted', () async {
      final fds = _malloc(8).cast<Int32>();
      expect(_pipe(fds), 0);
      final (readEnd, writeEnd) = (fds[0], fds[1]);
      _free(fds.cast());
      // Non-blocking write end: a write into a full pipe is EAGAIN.
      final nonBlocking = Platform.isMacOS ? 0x4 : 0x800;
      expect(_fcntl(writeEnd, 4 /* F_SETFL */, nonBlocking), 0);
      final path = '${dir.path}/nb.bin';
      File(path).writeAsBytesSync([]);
      nextOpen = (_) => {'fd': writeEnd, 'identifier': path, 'canFsync': false};
      final (scope, session) = await open('nb.bin');
      // A reader drains in parallel; start it before the writer blocks.
      final started = ReceivePort();
      final done = ReceivePort();
      await Isolate.spawn(_drainAndReport, (
        readEnd,
        started.sendPort,
        done.sendPort,
      ));
      await started.first;
      final writer = FdWriter.fromSession(session);
      final payload = Uint8List.fromList(List.generate(200000, (i) => i % 251));
      expect(writer.writeChunk(payload), 200000);
      await writer.closeWrite();
      expect(await done.first, payload);
      expect(closeFd(readEnd), 0);
      await plugin.release(scope);
    });

    test('sequential writes, no fsync, in order', () async {
      final fds = _malloc(8).cast<Int32>();
      expect(_pipe(fds), 0);
      final (readEnd, writeEnd) = (fds[0], fds[1]);
      _free(fds.cast());
      final path = '${dir.path}/pipe.bin';
      File(path).writeAsBytesSync([]);
      nextOpen = (_) => {'fd': writeEnd, 'identifier': path, 'canFsync': false};
      final (scope, session) = await open('pipe.bin');
      expect(session.canFsync, isFalse);
      final writer = FdWriter.fromSession(session, bufferLength: 16);
      expect(writer.writeChunk(bytes.sublist(0, 40)), 40);
      expect(writer.writeChunk(bytes.sublist(40)), 100);
      await writer.closeWrite();
      expect(drain(readEnd), bytes);
      expect(closeFd(readEnd), 0);
      await plugin.release(scope);
    });
  });

  test('stub platforms throw UnsupportedError', () async {
    final scope = await plugin.acquire(identifier: 'dir');
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await expectLater(
      plugin.openWrite(scope: scope, name: 'x'),
      throwsUnsupportedError,
    );
    debugDefaultTargetPlatformOverride = null;
    await plugin.release(scope);
  });
}

/// Signals it is running, drains the pipe [fd] to EOF, and sends the bytes.
void _drainAndReport((int, SendPort, SendPort) message) {
  final (fd, started, done) = message;
  started.send(true);
  done.send(drain(fd));
}

/// A helper that writes 100 bytes, reports, and waits to be killed.
void _writeAndWait((WriteHandoff, SendPort) message) {
  final (record, ready) = message;
  final writer = FdWriter.fromHandoff(record);
  ready.send(writer.writeChunk(Uint8List(100)));
  // Keep the writer reachable until the kill.
  ReceivePort().listen((_) => writer.bytesWritten);
}
