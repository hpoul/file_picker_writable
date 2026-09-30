// Faked-backend channel tests for openDirectory and acquire/release
// (R1 and Gap 1a, doc/scope-registry-plan.md §7).
//
// The native side is faked: these tests prove the Dart contract (argument
// shape, pairing, idempotent release, repair echo vs fresh identifier,
// error pass-through, platform stubs), not the native registries. Only a
// device run can prove grants survive a relaunch, stale bookmarks repair,
// and the iOS hold count balances.

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('design.codeux.file_picker_writable');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) backend;
  var nextToken = 0;

  Map<String, Object?> scopeResult(
    String identifier, {
    String? fresh,
    String? path,
  }) => <String, Object?>{
    'id': 'token-${nextToken++}',
    'identifier': fresh ?? identifier,
    'repaired': fresh != null,
    'path': path,
    'displayName': 'Trips',
  };

  setUp(() {
    calls = [];
    backend = (call) async => switch (call.method) {
      'acquire' => scopeResult((call.arguments as Map)['identifier'] as String),
      _ => null,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return backend(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('openDirectory', () {
    test('returns the picked folder as FileInfo', () async {
      backend = (call) async => <String, String>{
        'identifier': 'content://auth/tree/primary%3ATrips',
        'persistable': 'true',
        'uri': 'content://auth/tree/primary%3ATrips',
        'fileName': 'Trips',
      };
      final info = await FilePickerWritable().openDirectory();
      expect(calls.single.method, 'openDirectory');
      expect(info, isNotNull);
      expect(info!.identifier, 'content://auth/tree/primary%3ATrips');
      expect(info.persistable, isTrue);
      expect(info.fileName, 'Trips');
    });

    test('returns null on cancel', () async {
      backend = (call) async => null;
      expect(await FilePickerWritable().openDirectory(), isNull);
    });
  });

  group('acquire/release', () {
    test('acquire sends the identifier and a stable session', () async {
      final a = await FilePickerWritable().acquire(identifier: 'id-a');
      final b = await FilePickerWritable().acquire(identifier: 'id-b');
      final argsA = calls[0].arguments as Map;
      final argsB = calls[1].arguments as Map;
      expect(argsA['identifier'], 'id-a');
      expect(argsA['session'], isA<String>());
      expect(argsB['session'], argsA['session']);
      await FilePickerWritable().release(a);
      await FilePickerWritable().release(b);
    });

    test(
      'acquire-acquire-release-release: one native release per token',
      () async {
        final first = await FilePickerWritable().acquire(identifier: 'id');
        final second = await FilePickerWritable().acquire(identifier: 'id');
        expect(first.id, isNot(second.id));
        await FilePickerWritable().release(first);
        await FilePickerWritable().release(second);
        final releases = calls.where((c) => c.method == 'release').toList();
        expect(releases.map((c) => (c.arguments as Map)['id']), [
          first.id,
          second.id,
        ]);
      },
    );

    test(
      'double release is a no-op, never a native call or an error',
      () async {
        final scope = await FilePickerWritable().acquire(identifier: 'id');
        await FilePickerWritable().release(scope);
        await FilePickerWritable().release(scope);
        expect(calls.where((c) => c.method == 'release'), hasLength(1));
      },
    );

    test('release of a scope this isolate never acquired is a no-op', () async {
      final foreign = AcquiredScope(
        id: 'not-ours',
        identifier: 'id',
        repaired: false,
        path: null,
        displayName: 'x',
      );
      await FilePickerWritable().release(foreign);
      expect(calls, isEmpty);
    });

    test(
      'echo: identifier unchanged, repaired false, path passed through',
      () async {
        backend = (call) async => scopeResult('id', path: '/private/var/Trips');
        final scope = await FilePickerWritable().acquire(identifier: 'id');
        expect(scope.repaired, isFalse);
        expect(scope.identifier, 'id');
        expect(scope.path, '/private/var/Trips');
        expect(scope.displayName, 'Trips');
        await FilePickerWritable().release(scope);
      },
    );

    test('repair: fresh identifier with repaired true', () async {
      backend = (call) async => scopeResult('stale', fresh: 'fresh');
      final scope = await FilePickerWritable().acquire(identifier: 'stale');
      expect(scope.repaired, isTrue);
      expect(scope.identifier, 'fresh');
      await FilePickerWritable().release(scope);
    });

    test('Android shape: null path', () async {
      final scope = await FilePickerWritable().acquire(
        identifier: 'content://auth/tree/primary%3ATrips',
      );
      expect(scope.path, isNull);
      await FilePickerWritable().release(scope);
    });

    for (final kind in ['permission-lost', 'not-found']) {
      test(
        'taxonomy kind $kind passes through as PlatformException.code',
        () async {
          backend = (call) async => throw PlatformException(
            code: kind,
            message: 'native message',
            details: <String, Object?>{
              'domain': 'NSCocoaErrorDomain',
              'code': 4,
            },
          );
          await expectLater(
            FilePickerWritable().acquire(identifier: 'id'),
            throwsA(
              isA<PlatformException>()
                  .having((e) => e.code, 'code', kind)
                  .having((e) => (e.details as Map)['code'], 'native code', 4),
            ),
          );
        },
      );
    }

    test('a failed acquire holds nothing to release', () async {
      backend = (call) async =>
          throw PlatformException(code: 'permission-lost');
      await expectLater(
        FilePickerWritable().acquire(identifier: 'id'),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.where((c) => c.method == 'release'), isEmpty);
    });

    test('codes outside the taxonomy stay loud under their own code', () async {
      backend = (call) async =>
          throw PlatformException(code: 'java.lang.IllegalStateException');
      await expectLater(
        FilePickerWritable().acquire(identifier: 'id'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'java.lang.IllegalStateException',
          ),
        ),
      );
    });
  });

  group('stub platforms', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      test(
        '$platform throws UnsupportedError without a channel call',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          await expectLater(
            FilePickerWritable().openDirectory(),
            throwsUnsupportedError,
          );
          await expectLater(
            FilePickerWritable().acquire(identifier: 'id'),
            throwsUnsupportedError,
          );
          expect(calls, isEmpty);
        },
      );
    }

    test('iOS is supported', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final scope = await FilePickerWritable().acquire(identifier: 'id');
      await FilePickerWritable().release(scope);
      expect(calls.map((c) => c.method), ['acquire', 'release']);
    });
  });
}
