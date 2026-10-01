// Faked-backend channel tests for createDirectory, deleteEntry and
// moveEntry (Gap 3 tree verbs, doc/tree-writes-plan.md §7).
//
// The native side is faked: these tests prove the Dart contract (what is
// sent, the leaf-name pre-check, scope liveness before any channel call,
// error kinds passed through, platform stubs), not the providers. Only a
// device run can prove lookup-first, residue cleanup, the plugin's own
// recursion and the rollback.

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('design.codeux.file_picker_writable');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final plugin = FilePickerWritable();

  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) backend;
  var token = 0;

  Map<String, Object?> entry(String name, {bool isDirectory = true}) => {
    'name': name,
    'identifier': 'id:$name',
    'isDirectory': isDirectory,
    'size': null,
    'lastModified': 1790000000000,
  };

  setUp(() {
    calls = [];
    backend = (call) async => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'acquire') {
        return {
          'id': 'scope-${token++}',
          'identifier': 'dir',
          'repaired': false,
          'path': null,
          'displayName': 'dir',
        };
      }
      if (call.method == 'release') {
        return null;
      }
      calls.add(call);
      return backend(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Matcher kind(String code) =>
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', code));

  const badNames = ['', '.', '..', 'a/b', '../x', 'a\u0000b'];

  group('createDirectory', () {
    test('sends the parent scope and the name; returns the entry', () async {
      final scope = await plugin.acquire(identifier: 'dir');
      backend = (call) async => entry('2026 tour');
      final created = await plugin.createDirectory(
        scope: scope,
        name: '2026 tour',
      );
      expect(calls.single.method, 'createDirectory');
      expect(calls.single.arguments, {'scope': scope.id, 'name': '2026 tour'});
      expect(created.name, '2026 tour');
      expect(created.isDirectory, isTrue);
      expect(created.identifier, 'id:2026 tour');
      await plugin.release(scope);
    });

    test('a released scope is scope-closed before any channel call', () async {
      final scope = await plugin.acquire(identifier: 'dir');
      await plugin.release(scope);
      await expectLater(
        plugin.createDirectory(scope: scope, name: 'x'),
        kind('scope-closed'),
      );
      expect(calls, isEmpty);
    });

    for (final name in badNames) {
      test('leaf-name rule rejects ${name.isEmpty ? 'empty' : name}', () async {
        final scope = await plugin.acquire(identifier: 'dir');
        await expectLater(
          plugin.createDirectory(scope: scope, name: name),
          throwsArgumentError,
        );
        expect(calls, isEmpty);
        await plugin.release(scope);
      });
    }

    for (final code in ['already-exists', 'invalid-name', 'permission-lost']) {
      test('$code passes through', () async {
        final scope = await plugin.acquire(identifier: 'dir');
        backend = (call) async => throw PlatformException(code: code);
        await expectLater(
          plugin.createDirectory(scope: scope, name: 'x'),
          kind(code),
        );
        await plugin.release(scope);
      });
    }
  });

  group('deleteEntry', () {
    test('sends the identifier and recursive, default false', () async {
      await plugin.deleteEntry(identifier: 'id:a');
      await plugin.deleteEntry(identifier: 'id:b', recursive: true);
      expect(calls.map((c) => c.method), ['deleteEntry', 'deleteEntry']);
      expect(calls[0].arguments, {'identifier': 'id:a', 'recursive': false});
      expect(calls[1].arguments, {'identifier': 'id:b', 'recursive': true});
    });

    for (final code in ['directory-not-empty', 'root-protected']) {
      test('$code passes through', () async {
        backend = (call) async => throw PlatformException(code: code);
        await expectLater(plugin.deleteEntry(identifier: 'id:a'), kind(code));
      });
    }
  });

  group('moveEntry', () {
    test(
      'sends both scopes and the new name; returns the fresh entry',
      () async {
        final source = await plugin.acquire(identifier: 'dir');
        final target = await plugin.acquire(identifier: 'dir');
        backend = (call) async => entry('clip.mp4', isDirectory: false);
        final moved = await plugin.moveEntry(
          identifier: 'id:old.mp4',
          sourceParent: source,
          newParent: target,
          newName: 'clip.mp4',
        );
        expect(calls.single.method, 'moveEntry');
        expect(calls.single.arguments, {
          'identifier': 'id:old.mp4',
          'sourceParent': source.id,
          'newParent': target.id,
          'newName': 'clip.mp4',
        });
        expect(moved.identifier, 'id:clip.mp4');
        await plugin.release(source);
        await plugin.release(target);
      },
    );

    test('a pure move sends a null name', () async {
      final scope = await plugin.acquire(identifier: 'dir');
      backend = (call) async => entry('a', isDirectory: false);
      await plugin.moveEntry(
        identifier: 'id:a',
        sourceParent: scope,
        newParent: scope,
      );
      expect((calls.single.arguments as Map)['newName'], isNull);
      await plugin.release(scope);
    });

    test('either released scope is scope-closed before any call', () async {
      final live = await plugin.acquire(identifier: 'dir');
      final released = await plugin.acquire(identifier: 'dir');
      await plugin.release(released);
      await expectLater(
        plugin.moveEntry(
          identifier: 'id:a',
          sourceParent: live,
          newParent: released,
        ),
        kind('scope-closed'),
      );
      await expectLater(
        plugin.moveEntry(
          identifier: 'id:a',
          sourceParent: released,
          newParent: live,
        ),
        kind('scope-closed'),
      );
      expect(calls, isEmpty);
      await plugin.release(live);
    });

    for (final name in badNames) {
      test(
        'leaf-name rule rejects new name ${name.isEmpty ? 'empty' : name}',
        () async {
          final scope = await plugin.acquire(identifier: 'dir');
          await expectLater(
            plugin.moveEntry(
              identifier: 'id:a',
              sourceParent: scope,
              newParent: scope,
              newName: name,
            ),
            throwsArgumentError,
          );
          expect(calls, isEmpty);
          await plugin.release(scope);
        },
      );
    }

    for (final code in [
      'already-exists',
      'invalid-name',
      'move-partial',
      'unsupported-move',
      'root-protected',
    ]) {
      test('$code passes through with its details', () async {
        final scope = await plugin.acquire(identifier: 'dir');
        backend = (call) async => throw PlatformException(
          code: code,
          details: {'identifier': 'id:actual'},
        );
        await expectLater(
          plugin.moveEntry(
            identifier: 'id:a',
            sourceParent: scope,
            newParent: scope,
            newName: 'b',
          ),
          throwsA(
            isA<PlatformException>()
                .having((e) => e.code, 'code', code)
                .having(
                  (e) => (e.details as Map)['identifier'],
                  'identifier',
                  'id:actual',
                ),
          ),
        );
        await plugin.release(scope);
      });
    }
  });

  test(
    'stub platforms throw UnsupportedError without a channel call',
    () async {
      final scope = await plugin.acquire(identifier: 'dir');
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await expectLater(
        plugin.createDirectory(scope: scope, name: 'x'),
        throwsUnsupportedError,
      );
      await expectLater(
        plugin.deleteEntry(identifier: 'id:a'),
        throwsUnsupportedError,
      );
      await expectLater(
        plugin.moveEntry(
          identifier: 'id:a',
          sourceParent: scope,
          newParent: scope,
        ),
        throwsUnsupportedError,
      );
      expect(calls, isEmpty);
      debugDefaultTargetPlatformOverride = null;
      await plugin.release(scope);
    },
  );
}
