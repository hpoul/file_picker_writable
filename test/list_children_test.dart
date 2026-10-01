// Faked-backend channel tests for listChildren and lookupChild (Gap 1,
// doc/tree-traversal-plan.md §7).
//
// The native side is faked: these tests prove the Dart contract (wrapper
// shape, repair echo, null metadata, subdirectory round trip, lookup null
// vs loud parent, leaf-name pre-check, platform stubs), not the providers.
// Only a device run can prove the cursor pass, the derived child ID and
// dotfile visibility.

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

  Map<String, Object?> entry(
    String name, {
    bool isDirectory = false,
    int? size = 3,
    int? lastModified = 1790000000000,
  }) => <String, Object?>{
    'name': name,
    'identifier': 'id:$name',
    'isDirectory': isDirectory,
    'size': size,
    'lastModified': lastModified,
  };

  setUp(() {
    calls = [];
    backend = (call) async => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return backend(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('listChildren', () {
    test('wrapper shape: entries, identifier echo, repaired false', () async {
      backend = (call) async => <String, Object?>{
        'identifier': 'dir',
        'repaired': false,
        'entries': [
          entry('trip.json'),
          entry('media', isDirectory: true, size: null),
          entry('.howitwent'),
        ],
      };
      final listing = await FilePickerWritable().listChildren(
        identifier: 'dir',
      );
      expect(calls.single.method, 'listChildren');
      expect((calls.single.arguments as Map)['identifier'], 'dir');
      expect(listing.identifier, 'dir');
      expect(listing.repaired, isFalse);
      expect(listing.entries.map((e) => e.name), [
        'trip.json',
        'media',
        '.howitwent',
      ]);
      final media = listing.entries[1];
      expect(media.isDirectory, isTrue);
      expect(media.identifier, 'id:media');
      expect(
        listing.entries.first.lastModified,
        DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true),
      );
    });

    test('stale parent: fresh identifier with repaired true', () async {
      backend = (call) async => <String, Object?>{
        'identifier': 'fresh',
        'repaired': true,
        'entries': <Object?>[],
      };
      final listing = await FilePickerWritable().listChildren(
        identifier: 'stale',
      );
      expect(listing.identifier, 'fresh');
      expect(listing.repaired, isTrue);
    });

    test('empty directory', () async {
      backend = (call) async => <String, Object?>{
        'identifier': 'dir',
        'repaired': false,
        'entries': <Object?>[],
      };
      final listing = await FilePickerWritable().listChildren(
        identifier: 'dir',
      );
      expect(listing.entries, isEmpty);
    });

    test('null size and lastModified pass through as null', () async {
      backend = (call) async => <String, Object?>{
        'identifier': 'dir',
        'repaired': false,
        'entries': [entry('clip.mp4', size: null, lastModified: null)],
      };
      final child = (await FilePickerWritable().listChildren(
        identifier: 'dir',
      )).entries.single;
      expect(child.size, isNull);
      expect(child.lastModified, isNull);
    });

    test(
      'lastModified 0 from any platform is "won\'t say", size 0 stays',
      () async {
        // iOS passes a provider's 0 through; the rule lives in Dart.
        backend = (call) async => <String, Object?>{
          'identifier': 'dir',
          'repaired': false,
          'entries': [entry('empty.txt', size: 0, lastModified: 0)],
        };
        final child = (await FilePickerWritable().listChildren(
          identifier: 'dir',
        )).entries.single;
        expect(child.lastModified, isNull);
        expect(child.size, 0);
      },
    );

    test(
      'iOS shape: the shared prefix is sent once and composed per entry',
      () async {
        const prefix = 'fpwchild1:QUJD:Trips/';
        backend = (call) async => <String, Object?>{
          'identifier': 'dir',
          'repaired': false,
          'identifierPrefix': prefix,
          'entries': [
            {
              'name': 'trip.json',
              'identifierSuffix': 'trip.json',
              'isDirectory': false,
              'size': 3,
              'lastModified': 1790000000000,
            },
            {
              'name': 'ü 日本',
              'identifierSuffix': '%C3%BC%20%E6%97%A5%E6%9C%AC',
              'isDirectory': true,
              'size': null,
              'lastModified': null,
            },
          ],
        };
        final entries = (await FilePickerWritable().listChildren(
          identifier: 'dir',
        )).entries;
        expect(entries.map((e) => e.identifier), [
          '${prefix}trip.json',
          '$prefix%C3%BC%20%E6%97%A5%E6%9C%AC',
        ]);
      },
    );

    test('a composed identifier goes back to native whole', () async {
      backend = (call) async => switch ((call.arguments as Map)['identifier']) {
        'dir' => <String, Object?>{
          'identifier': 'dir',
          'repaired': false,
          'identifierPrefix': 'P:',
          'entries': [
            {
              'name': 'media',
              'identifierSuffix': 'media',
              'isDirectory': true,
              'size': null,
              'lastModified': null,
            },
          ],
        },
        _ => <String, Object?>{
          'identifier': (call.arguments as Map)['identifier'],
          'repaired': false,
          'entries': <Object?>[],
        },
      };
      final media = (await FilePickerWritable().listChildren(
        identifier: 'dir',
      )).entries.single;
      await FilePickerWritable().listChildren(identifier: media.identifier);
      expect((calls.last.arguments as Map)['identifier'], 'P:media');
    });

    test(
      'a suffix without a prefix is loud, not a truncated identifier',
      () async {
        backend = (call) async => <String, Object?>{
          'identifier': 'dir',
          'repaired': false,
          'entries': [
            {
              'name': 'x',
              'identifierSuffix': 'x',
              'isDirectory': false,
              'size': 1,
              'lastModified': 1,
            },
          ],
        };
        await expectLater(
          FilePickerWritable().listChildren(identifier: 'dir'),
          throwsStateError,
        );
      },
    );

    for (final (label, keys) in [
      ('both identifier kinds', {'identifier': 'P:x', 'identifierSuffix': 'x'}),
      ('neither identifier kind', <String, String>{}),
    ]) {
      test('an entry with $label is loud', () async {
        backend = (call) async => <String, Object?>{
          'identifier': 'dir',
          'repaired': false,
          'identifierPrefix': 'P:',
          'entries': [
            {
              'name': 'x',
              ...keys,
              'isDirectory': false,
              'size': 1,
              'lastModified': 1,
            },
          ],
        };
        await expectLater(
          FilePickerWritable().listChildren(identifier: 'dir'),
          throwsStateError,
        );
      });
    }

    test('a subdirectory identifier round-trips back in', () async {
      backend = (call) async {
        final id = (call.arguments as Map)['identifier'];
        return <String, Object?>{
          'identifier': id,
          'repaired': false,
          'entries': [
            if (id == 'root') ...[entry('media', isDirectory: true)],
            if (id == 'id:media') ...[entry('clip.mp4')],
          ],
        };
      };
      final root = await FilePickerWritable().listChildren(identifier: 'root');
      final media = await FilePickerWritable().listChildren(
        identifier: root.entries.single.identifier,
      );
      expect(media.entries.single.name, 'clip.mp4');
      expect((calls.last.arguments as Map)['identifier'], 'id:media');
    });

    for (final kind in ['permission-lost', 'not-found', 'not-a-directory']) {
      test('$kind passes through as PlatformException.code', () async {
        backend = (call) async => throw PlatformException(code: kind);
        await expectLater(
          FilePickerWritable().listChildren(identifier: 'dir'),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', kind)),
        );
      });
    }
  });

  group('lookupChild', () {
    test('hit returns the entry', () async {
      backend = (call) async => entry('trip.json');
      final child = await FilePickerWritable().lookupChild(
        identifier: 'dir',
        name: 'trip.json',
      );
      expect(calls.single.method, 'lookupChild');
      expect(calls.single.arguments, {
        'identifier': 'dir',
        'name': 'trip.json',
      });
      expect(child!.name, 'trip.json');
    });

    test('absent child is null, not an error', () async {
      backend = (call) async => null;
      expect(
        await FilePickerWritable().lookupChild(
          identifier: 'dir',
          name: '.prev',
        ),
        isNull,
      );
    });

    test('a gone parent is loud not-found', () async {
      backend = (call) async => throw PlatformException(code: 'not-found');
      await expectLater(
        FilePickerWritable().lookupChild(identifier: 'dir', name: 'x'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'not-found'),
        ),
      );
    });

    test('dotfiles are ordinary names', () async {
      backend = (call) async => entry('.howitwent');
      final child = await FilePickerWritable().lookupChild(
        identifier: 'dir',
        name: '.howitwent',
      );
      expect(child!.name, '.howitwent');
    });

    for (final name in ['', '.', '..', 'a/b', '../x', 'a\u0000b']) {
      test('leaf-name rule rejects ${name.isEmpty ? 'empty' : name} '
          'before any channel call', () async {
        await expectLater(
          FilePickerWritable().lookupChild(identifier: 'dir', name: name),
          throwsArgumentError,
        );
        expect(calls, isEmpty);
      });
    }
  });

  test(
    'stub platforms throw UnsupportedError without a channel call',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await expectLater(
        FilePickerWritable().listChildren(identifier: 'dir'),
        throwsUnsupportedError,
      );
      await expectLater(
        FilePickerWritable().lookupChild(identifier: 'dir', name: 'x'),
        throwsUnsupportedError,
      );
      expect(calls, isEmpty);
    },
  );
}
