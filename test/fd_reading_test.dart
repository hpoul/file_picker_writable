// FFI tests for the fd byte path (Gap 2b, doc/large-file-reads-plan.md §7):
// real descriptors and the real shim (built for the host by
// hook/build.dart), with only the openRead control call faked. They prove
// the Dart side: views, end of file, bounds, the single-owner rules,
// handoff and its recovery, a helper isolate, the kill path closing through
// the finalizer, pipes, and scope liveness. Only a device run can prove the
// providers' descriptors and the errno set after a detach.

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
final _write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');

/// A read-only descriptor for [path], opened through libc.
int openReadOnly(String path) {
  final bytes = Uint8List.fromList([...path.codeUnits, 0]);
  final native = _malloc(bytes.length);
  native.asTypedList(bytes.length).setAll(0, bytes);
  try {
    final fd = _open(native, 0 /* O_RDONLY */, 0);
    expect(fd, greaterThanOrEqualTo(0), reason: 'open $path');
    return fd;
  } finally {
    _free(native);
  }
}

/// A pipe holding [content] with its write end closed: (read end).
int pipeWith(List<int> content) {
  final fds = _malloc(8).cast<Int32>();
  try {
    expect(_pipe(fds), 0);
    final buffer = _malloc(content.length);
    buffer.asTypedList(content.length).setAll(0, content);
    expect(_write(fds[1], buffer, content.length), content.length);
    _free(buffer);
    expect(fpw_close(fds[1]), 0);
    return fds[0];
  } finally {
    _free(fds.cast());
  }
}

final _fcntl = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');

/// True when [fd] is not open. F_GETFD only asks, so a number the VM has
/// reused meanwhile is never closed by the probe.
bool isClosed(int fd) => _fcntl(fd, 1 /* F_GETFD */, 0) == -1;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('design.codeux.file_picker_writable');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final plugin = FilePickerWritable();

  late Directory dir;
  late Uint8List content;
  late String filePath;
  late Map<String, Object?> Function() nextOpen;
  var token = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fpw-fd-');
    content = Uint8List.fromList(
      List.generate(3 * 1024 * 1024 + 17, (i) => i * 31 % 251),
    );
    filePath = '${dir.path}/media.bin';
    File(filePath).writeAsBytesSync(content);
    nextOpen = () => {
      'fd': openReadOnly(filePath),
      'seekable': true,
      'length': content.length,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'acquire' => {
          'id': 'scope-${token++}',
          'identifier': 'id',
          'repaired': false,
          'path': null,
          'displayName': 'media.bin',
        },
        'openRead' => nextOpen(),
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    dir.deleteSync(recursive: true);
  });

  Future<(AcquiredScope, ReadSession)> open() async {
    final scope = await plugin.acquire(identifier: 'id');
    return (scope, await plugin.openRead(scope: scope));
  }

  group('openRead', () {
    test('sends the scope token and reports what native opened', () async {
      final (scope, session) = await open();
      expect(session.seekable, isTrue);
      expect(session.length, content.length);
      await plugin.closeRead(session);
      expect(isClosed(session.fd), isTrue);
      await plugin.release(scope);
    });

    test('a released scope is scope-closed before any channel call', () async {
      final scope = await plugin.acquire(identifier: 'id');
      await plugin.release(scope);
      await expectLater(
        plugin.openRead(scope: scope),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'scope-closed',
          ),
        ),
      );
    });

    test('stub platforms throw UnsupportedError', () async {
      final scope = await plugin.acquire(identifier: 'id');
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await expectLater(plugin.openRead(scope: scope), throwsUnsupportedError);
      debugDefaultTargetPlatformOverride = null;
      await plugin.release(scope);
    });
  });

  group('FdReader on the same isolate', () {
    test(
      'positional reads return views of the file, empty at the end',
      () async {
        final (scope, session) = await open();
        final reader = FdReader.fromSession(session);
        // Under 1 MiB in all: the root isolate's budget (a helper reads
        // the whole file in the handoff tests).
        expect(reader.readChunk(0, 1 << 16), content.sublist(0, 1 << 16));
        expect(
          reader.readChunk(2 * 1024 * 1024, 1 << 16),
          content.sublist(2 * 1024 * 1024, 2 * 1024 * 1024 + (1 << 16)),
        );
        // The last, short chunk loops to end of file.
        expect(
          reader.readChunk(3 * 1024 * 1024, 1 << 20),
          content.sublist(3 * 1024 * 1024),
        );
        expect(reader.readChunk(content.length, 1 << 20), isEmpty);
        expect(reader.readChunk(content.length + 5, 10), isEmpty);
        reader.close();
        expect(isClosed(session.fd), isTrue);
        await plugin.release(scope);
      },
    );

    test('a view is valid until the next call: the buffer is reused', () async {
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session, bufferLength: 16);
      final first = reader.readChunk(0, 4);
      final kept = Uint8List.fromList(first);
      reader.readChunk(100, 4);
      expect(
        first,
        content.sublist(100, 104),
        reason: 'same native bytes, overwritten',
      );
      expect(kept, content.sublist(0, 4));
      reader.close();
      await plugin.release(scope);
    });

    test('bounds are ArgumentErrors, never clamps', () async {
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session, bufferLength: 16);
      expect(() => reader.readChunk(-1, 4), throwsArgumentError);
      expect(() => reader.readChunk(0, -1), throwsArgumentError);
      expect(() => reader.readChunk(0, 17), throwsArgumentError);
      expect(reader.readChunk(0, 0), isEmpty);
      reader.close();
      await plugin.release(scope);
    });

    test('close is idempotent; reads after close are session-closed', () async {
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session)..close();
      reader.close();
      expect(
        () => reader.readChunk(0, 1),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'session-closed',
          ),
        ),
      );
      // The session is closed with it: closeRead is the idempotent no-op.
      await plugin.closeRead(session);
      await plugin.release(scope);
    });

    test('closeRead on a wrapped session closes the reader', () async {
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session);
      await plugin.closeRead(session);
      expect(isClosed(session.fd), isTrue);
      expect(
        () => reader.readChunk(0, 1),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'session-closed',
          ),
        ),
      );
      await plugin.release(scope);
    });

    test('one reader per session', () async {
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session);
      expect(() => FdReader.fromSession(session), throwsStateError);
      reader.close();
      expect(() => FdReader.fromSession(session), throwsStateError);
      await plugin.release(scope);
    });

    test(
      'a scope released mid-read: close still cleans up, then throws',
      () async {
        final (scope, session) = await open();
        final reader = FdReader.fromSession(session);
        await plugin.release(scope);
        expect(
          reader.close,
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'scope-closed',
            ),
          ),
        );
        expect(isClosed(session.fd), isTrue);
      },
    );

    test('wrapping needs a live scope', () async {
      final (scope, session) = await open();
      await plugin.release(scope);
      expect(
        () => FdReader.fromSession(session),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'scope-closed',
          ),
        ),
      );
      await plugin.closeRead(session);
    });

    test('a view kept past close stays readable memory', () async {
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session, bufferLength: 16);
      final view = reader.readChunk(0, 8);
      reader.close();
      // The buffer belongs to Dart and the view keeps it alive: stale
      // bytes at worst, never freed memory.
      expect(view, content.sublist(0, 8));
      await plugin.release(scope);
    });

    test('close detaches the finalizer: a GC never closes again', () async {
      final (scope, session) = await open();
      final weak = _closeAndForget(session);
      // The lowest free number: most likely the one just closed, now a
      // fresh descriptor that a stale finalizer would close.
      final (secondScope, second) = await open();
      final reader = FdReader.fromSession(second);
      final garbage = <Object>[];
      for (var i = 0; weak.target != null && i < 50000; i++) {
        garbage.add(Uint8List(1 << 16));
        if (garbage.length > 64) {
          garbage.clear();
        }
      }
      expect(weak.target, isNull, reason: 'the first reader was collected');
      expect(isClosed(second.fd), isFalse);
      expect(reader.readChunk(0, 4), content.sublist(0, 4));
      reader.close();
      await plugin.release(secondScope);
      await plugin.release(scope);
    });

    test('an errno outside the taxonomy stays loud as errno-<n>', () async {
      // A pipe reported as seekable: pread fails with ESPIPE (29).
      nextOpen = () => {
        'fd': pipeWith([1, 2, 3]),
        'seekable': true,
        'length': 3,
      };
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session);
      expect(
        () => reader.readChunk(0, 3),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'errno-29')
              .having((e) => (e.details as Map)['domain'], 'domain', 'errno'),
        ),
      );
      reader.close();
      await plugin.release(scope);
    });

    test('EBADF is session-closed, never a live read', () async {
      final (scope, session) = await open();
      expect(
        fpw_close(session.fd),
        0,
        reason: 'closed behind the reader’s back',
      );
      final reader = FdReader.fromSession(session);
      expect(
        () => reader.readChunk(0, 1),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'session-closed')
              .having((e) => (e.details as Map)['code'], 'errno', 9),
        ),
      );
      expect(reader.close, throwsA(isA<PlatformException>()));
      await plugin.release(scope);
    });
  });

  group('handoff', () {
    test('a helper isolate reads and closes; the root copy is dead', () async {
      final (scope, session) = await open();
      final record = session.handoff();
      final firstBytes = await Isolate.run(_readFirstKiB(record));
      expect(firstBytes, content.sublist(0, 1024));
      expect(isClosed(record.fd), isTrue);
      expect(() => FdReader.fromSession(session), throwsStateError);
      expect(plugin.closeRead(session), throwsStateError);
      expect(session.handoff, throwsStateError);
      await plugin.release(scope);
    });

    test('handoff after a reader was built is a StateError', () async {
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session);
      expect(session.handoff, throwsStateError);
      reader.close();
      await plugin.release(scope);
    });

    test('handoff checks the scope', () async {
      final (scope, session) = await open();
      await plugin.release(scope);
      expect(
        session.handoff,
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'scope-closed',
          ),
        ),
      );
      await plugin.closeRead(session);
    });

    test(
      'a record consumed twice is a StateError, not a double close',
      () async {
        final (scope, session) = await open();
        final record = session.handoff();
        final first = FdReader.fromHandoff(record);
        expect(() => FdReader.fromHandoff(record), throwsStateError);
        expect(first.readChunk(0, 4), content.sublist(0, 4));
        first.close();
        expect(isClosed(record.fd), isTrue);
        await plugin.release(scope);
      },
    );

    test('recovery: the root builds the reader from its own record', () async {
      final (scope, session) = await open();
      final record = session.handoff();
      // The spawn itself failed (IsolateSpawnException): nobody took it, so
      // the root is the consumer. The only case recovery is allowed.
      final reader = FdReader.fromHandoff(record);
      expect(reader.readChunk(10, 4), content.sublist(10, 14));
      reader.close();
      expect(isClosed(record.fd), isTrue);
      await plugin.release(scope);
    });

    test('kill: the dead helper’s finalizer closes the descriptor', () async {
      final (scope, session) = await open();
      final record = session.handoff();
      final ready = ReceivePort();
      final exited = ReceivePort();
      final helper = await Isolate.spawn(_holdReader, (
        record,
        ready.sendPort,
      ), onExit: exited.sendPort);
      await ready.first;
      helper.kill(priority: Isolate.immediate);
      await exited.first;
      expect(
        isClosed(record.fd),
        isTrue,
        reason: 'closed exactly once, by the finalizer',
      );
      await plugin.release(scope);
    });
  });

  group('pipes', () {
    test(
      'sequential reads, forward skips, backward is seek-unsupported',
      () async {
        final bytes = List.generate(100, (i) => i);
        nextOpen = () => {
          'fd': pipeWith(bytes),
          'seekable': false,
          'length': null,
        };
        final (scope, session) = await open();
        expect(session.seekable, isFalse);
        expect(session.length, isNull);
        final reader = FdReader.fromSession(session, bufferLength: 16);
        expect(reader.readChunk(0, 10), bytes.sublist(0, 10));
        // Forward: skips 40 bytes by reading them.
        expect(reader.readChunk(50, 10), bytes.sublist(50, 60));
        expect(
          () => reader.readChunk(0, 10),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'seek-unsupported',
            ),
          ),
        );
        expect(reader.readChunk(60, 16), bytes.sublist(60, 76));
        expect(reader.readChunk(76, 16), bytes.sublist(76, 92));
        expect(reader.readChunk(92, 16), bytes.sublist(92));
        expect(reader.readChunk(100, 16), isEmpty);
        reader.close();
        await plugin.release(scope);
      },
    );

    test('short reads loop until the length is there', () async {
      final fds = _malloc(8).cast<Int32>();
      expect(_pipe(fds), 0);
      final (readEnd, writeEnd) = (fds[0], fds[1]);
      _free(fds.cast());
      nextOpen = () => {'fd': readEnd, 'seekable': false, 'length': null};
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session, bufferLength: 64);
      // Three writes with pauses: each read(2) returns only what is there,
      // so one 30-byte chunk takes several reads inside the shim. Read only
      // once the writer is running, or this isolate would block in read(2)
      // before the writer exists.
      final firstPart = ReceivePort();
      final exited = ReceivePort();
      await Isolate.spawn(_writeInParts, (
        writeEnd,
        firstPart.sendPort,
      ), onExit: exited.sendPort);
      await firstPart.first;
      expect(reader.readChunk(0, 30), List.generate(30, (i) => i));
      await exited.first;
      expect(reader.readChunk(30, 64), isEmpty);
      reader.close();
      await plugin.release(scope);
    });
  });

  group('root isolate budget', () {
    test('more than 1 MiB on the root isolate asserts', () async {
      expect(RootIsolateToken.instance, isNotNull);
      final (scope, session) = await open();
      final reader = FdReader.fromSession(session);
      reader.readChunk(0, 1 << 20);
      expect(
        () => reader.readChunk(1 << 20, 1),
        throwsA(isA<AssertionError>()),
      );
      reader.close();
      await plugin.release(scope);
    });
  });
}

/// Builds a reader on [session]'s handoff record (so no session links to
/// it), closes it, and drops it: only the weak reference is left, to watch
/// for its collection.
WeakReference<FdReader> _closeAndForget(ReadSession session) {
  final reader = FdReader.fromHandoff(session.handoff())..close();
  return WeakReference(reader);
}

/// Writes 0..29 to the pipe's write end in three parts with pauses, then
/// closes it, and reports the first part written on the port.
void _writeInParts((int, SendPort) message) {
  final (fd, firstPart) = message;
  final buffer = _malloc(10);
  for (var part = 0; part < 3; part++) {
    buffer.asTypedList(10).setAll(0, List.generate(10, (i) => part * 10 + i));
    if (_write(fd, buffer, 10) != 10) {
      throw StateError('write failed');
    }
    if (part == 0) {
      firstPart.send(true);
    }
    sleep(const Duration(milliseconds: 50));
  }
  _free(buffer);
  fpw_close(fd);
}

/// The helper's work, built at top level so the closure captures only the
/// record (a closure inside the test would capture its unsendable context).
Uint8List Function() _readFirstKiB(ReadHandoff record) => () {
  final reader = FdReader.fromHandoff(record);
  try {
    return Uint8List.fromList(reader.readChunk(0, 1024));
  } finally {
    reader.close();
  }
};

/// A helper that builds its reader and then waits to be killed.
void _holdReader((ReadHandoff, SendPort) message) {
  final (record, ready) = message;
  final reader = FdReader.fromHandoff(record);
  reader.readChunk(0, 1);
  ready.send(true);
  // Keep the reader reachable until the kill.
  ReceivePort().listen((_) => reader.close());
}
