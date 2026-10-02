// Faked-backend channel tests for entryState.
//
// The native side is faked: these tests prove the Dart contract (what is
// sent, every wire answer mapped, loud failures passed through, platform
// stubs), not the checks. Only a device run can prove the order of the
// checks and the open.

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

  test('sends the identifier exactly as given', () async {
    // A content URI with an encoded colon and slash, which a Uri round
    // trip would normalize.
    const identifier =
        'content://com.android.externalstorage.documents/tree/'
        '3C61-1EFF%3ARides/document/3C61-1EFF%3ARides%2Fclip.mp4';
    backend = (call) async => 'readable';
    await plugin.entryState(identifier: identifier);
    expect(calls.single.method, 'entryState');
    expect(calls.single.arguments, {'identifier': identifier});
  });

  test('maps every wire answer', () async {
    const wire = {
      'readable': EntryState.readable,
      'volume-absent': EntryState.volumeAbsent,
      'permission-lost': EntryState.permissionLost,
      'not-found': EntryState.notFound,
      'not-a-file': EntryState.notAFile,
    };
    expect(wire.values.toSet(), EntryState.values.toSet());
    for (final MapEntry(key: answer, value: state) in wire.entries) {
      backend = (call) async => answer;
      expect(await plugin.entryState(identifier: 'id'), state);
    }
  });

  test('an unknown answer or no answer is a StateError', () async {
    backend = (call) async => 'mounting';
    await expectLater(
      plugin.entryState(identifier: 'id'),
      throwsA(isA<StateError>()),
    );
    backend = (call) async => null;
    await expectLater(
      plugin.entryState(identifier: 'id'),
      throwsA(isA<StateError>()),
    );
  });

  test('a loud native failure passes through with its details', () async {
    backend = (call) async => throw PlatformException(
      code: 'java.lang.IllegalStateException',
      message: 'Cannot tell whether it is gone',
      details: {
        'domain': 'java',
        'code': 'java.lang.IllegalStateException',
        'message': 'Cannot tell whether it is gone',
      },
    );
    await expectLater(
      plugin.entryState(identifier: 'id'),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'java.lang.IllegalStateException')
            .having(
              (e) => (e.details as Map)['message'],
              'details.message',
              'Cannot tell whether it is gone',
            ),
      ),
    );
  });

  test('stub platforms throw UnsupportedError without a channel call', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(() => plugin.entryState(identifier: 'id'), throwsUnsupportedError);
    expect(calls, isEmpty);
  });
}
