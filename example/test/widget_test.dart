import 'package:file_picker_writable_example/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // FilePickerWritable() talks to native code over these channels, but
    // widget tests have no host platform, so answer with benign defaults.
    const methodChannel = MethodChannel('design.codeux.file_picker_writable');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async => null);
    const eventChannel =
        MethodChannel('design.codeux.file_picker_writable/events');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(eventChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('design.codeux.file_picker_writable'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('design.codeux.file_picker_writable/events'),
            null);
  });

  testWidgets('Example app shows file picker buttons',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('File Picker Example'), findsOneWidget);
    expect(find.text('Open File Picker'), findsOneWidget);
    expect(find.text('Create New File'), findsOneWidget);
  });
}
