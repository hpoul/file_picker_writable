// Faked-backend channel tests for drop intake.
//
// The native side is faked: these tests prove the Dart contract (grouped
// delivery, FileInfo shape, hover callbacks, temp cleanup, pending queue)
// — not the Android behavior. Only a real device/emulator drop
// can prove:
// - the activity content view receives drag events (STARTED accepted),
// - requestDragAndDropPermissions grants readable URIs and every copy
//   completes before release (copy-before-release),
// - multi-item ClipData from the Files app arrives as one group,
// - DISPLAY_NAME queries (and lastPathSegment fallbacks) yield file names
//   from real providers,
// - hover entered/exited fire exactly once per transition,
// - drops while the app is backgrounded/detached behave sanely.

import 'dart:io';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('design.codeux.file_picker_writable');
  const eventChannel =
      MethodChannel('design.codeux.file_picker_writable/events');

  late FilePickerState pickerState;
  late Directory tempDir;

  Future<void> fireDrop(List<Map<String, String>> files) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    return messenger.handlePlatformMessage(
      methodChannel.name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall('handleDrop', {'files': files})),
      (_) {},
    );
  }

  Future<void> fireHover(String method) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    return messenger.handlePlatformMessage(
      methodChannel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  Future<void> waitFor(
    bool Function() condition, {
    String description = 'condition',
  }) async {
    const deadline = Duration(seconds: 2);
    final stopwatch = Stopwatch()..start();
    while (!condition()) {
      if (stopwatch.elapsed > deadline) {
        fail('Timed out waiting for $description');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Map<String, String> dropFile(String name, String contents) {
    final file = File('${tempDir.path}/$name')
      ..writeAsStringSync(contents);
    return <String, String>{
      'path': file.path,
      'identifier': 'content://example/$name',
      'persistable': 'false',
      'uri': 'content://example/$name',
      'fileName': name,
    };
  }

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methodChannel, (call) async => null);
    messenger.setMockMethodCallHandler(eventChannel, (call) async => null);
    pickerState = FilePickerWritable().init();
    tempDir = Directory.systemTemp.createTempSync('drop_intake_test');
  });

  tearDown(() async {
    // Drain any pending drop so singleton state never leaks between tests.
    // Lock ordering guarantees the drain consumes before a later test's
    // registration can observe the stale event.
    Future<bool> drain(DropEvent _) async => true;
    pickerState.registerDropHandler(drain);
    pickerState.removeDropHandler(drain);
    await tempDir.delete(recursive: true);
  });

  test('delivers one drop session as a grouped DropEvent', () async {
    final received = <DropEvent>[];
    final filesPresentAtDelivery = <bool>[];
    Future<bool> onDrop(DropEvent drop) async {
      received.add(drop);
      filesPresentAtDelivery.addAll(
          drop.items.map((item) => File(item.file.path).existsSync()));
      return true;
    }

    pickerState.registerDropHandler(onDrop);
    try {
      await fireDrop([
        dropFile('a.txt', 'aaa'),
        dropFile('b.txt', 'bbb'),
      ]);

      expect(received, hasLength(1));
      final items = received.single.items;
      expect(items, hasLength(2));
      expect(filesPresentAtDelivery, everyElement(isTrue));
      expect(items[0].fileInfo.fileName, 'a.txt');
      expect(items[0].fileInfo.identifier, 'content://example/a.txt');
      expect(items[0].fileInfo.uri, 'content://example/a.txt');
      expect(items[0].fileInfo.persistable, isFalse);
      expect(items[1].fileInfo.fileName, 'b.txt');
    } finally {
      pickerState.removeDropHandler(onDrop);
    }
  });

  test('deletes temp files once the drop is handled', () async {
    Future<bool> onDrop(DropEvent _) async => true;
    pickerState.registerDropHandler(onDrop);
    try {
      final first = dropFile('gone.txt', 'gone');
      await fireDrop([first]);
      await waitFor(() => !File(first['path']!).existsSync(),
          description: 'temp file deletion');
    } finally {
      pickerState.removeDropHandler(onDrop);
    }
  });

  test('forwards drag hover entered and exited', () async {
    // No handler registered: must not throw and queues nothing.
    await fireHover('dragEntered');

    final hovered = <bool>[];
    void onHover(bool entered) => hovered.add(entered);
    pickerState.registerDropHoverHandler(onHover);
    try {
      await fireHover('dragEntered');
      await fireHover('dragExited');
      expect(hovered, [true, false]);
    } finally {
      pickerState.removeDropHoverHandler(onHover);
    }
  });

  test('delivers pending drops to late handlers', () async {
    final late = dropFile('late.txt', 'late');
    await fireDrop([late]);

    final received = <DropEvent>[];
    Future<bool> onDrop(DropEvent drop) async {
      received.add(drop);
      return true;
    }
    pickerState.registerDropHandler(onDrop);
    try {
      await waitFor(() => received.isNotEmpty,
          description: 'pending drop delivery');
      expect(received.single.items.single.fileInfo.fileName, 'late.txt');
      // The pending path must clean up exactly like direct dispatch.
      await waitFor(() => !File(late['path']!).existsSync(),
          description: 'pending temp file deletion');
    } finally {
      pickerState.removeDropHandler(onDrop);
    }
  });

  test('queues drops that arrive before any handler registers', () async {
    await fireDrop([dropFile('first.txt', 'first')]);
    await fireDrop([dropFile('second.txt', 'second')]);

    final received = <DropEvent>[];
    Future<bool> onDrop(DropEvent drop) async {
      received.add(drop);
      return true;
    }
    pickerState.registerDropHandler(onDrop);
    try {
      await waitFor(() => received.length == 2,
          description: 'queued drop delivery');
      expect(
          received.map((drop) => drop.items.single.fileInfo.fileName),
          ['first.txt', 'second.txt']);
    } finally {
      pickerState.removeDropHandler(onDrop);
    }
  });

  test('passes identifiers through unfiltered', () async {
    final file = File('${tempDir.path}/odd.bin')
      ..writeAsStringSync('odd');
    final received = <DropEvent>[];
    Future<bool> onDrop(DropEvent drop) async {
      received.add(drop);
      return true;
    }
    pickerState.registerDropHandler(onDrop);
    try {
      await fireDrop([
        <String, String>{
          'path': file.path,
          'identifier': 'weird-scheme://odd?x=1#frag',
          'persistable': 'false',
          'uri': 'content://odd/provider',
        },
      ]);
      final fileInfo = received.single.items.single.fileInfo;
      expect(fileInfo.identifier, 'weird-scheme://odd?x=1#frag');
      expect(fileInfo.uri, 'content://odd/provider');
      expect(fileInfo.fileName, isNull);
    } finally {
      pickerState.removeDropHandler(onDrop);
    }
  });

  test('removed handlers no longer fire', () async {
    var dropCalls = 0;
    Future<bool> onDrop(DropEvent _) async {
      dropCalls++;
      return true;
    }
    pickerState.registerDropHandler(onDrop);
    expect(pickerState.removeDropHandler(onDrop), isTrue);

    var hoverCalls = 0;
    void onHover(bool _) => hoverCalls++;
    pickerState.registerDropHoverHandler(onHover);
    expect(pickerState.removeDropHoverHandler(onHover), isTrue);

    await fireDrop([dropFile('orphan.txt', 'orphan')]);
    await fireHover('dragEntered');

    expect(dropCalls, 0);
    expect(hoverCalls, 0);
  });
}
