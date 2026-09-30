import 'dart:io';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FileInfo JSON round-trip preserves all fields', () {
    final fileInfo = FileInfo(
      identifier: 'test-identifier',
      persistable: true,
      uri: 'content://example/document/1',
      fileName: 'notes.txt',
    );
    final decoded = FileInfo.fromJsonString(fileInfo.toJsonString());
    expect(decoded.identifier, fileInfo.identifier);
    expect(decoded.persistable, fileInfo.persistable);
    expect(decoded.uri, fileInfo.uri);
    expect(decoded.fileName, fileInfo.fileName);
  });

  test('FileInfo.fromJson handles missing fileName', () {
    final decoded = FileInfo.fromJson(<String, dynamic>{
      'identifier': 'id',
      'persistable': 'false',
      'uri': 'file:///tmp/example.txt',
    });
    expect(decoded.identifier, 'id');
    expect(decoded.persistable, isFalse);
    expect(decoded.uri, 'file:///tmp/example.txt');
    expect(decoded.fileName, isNull);
  });

  test('writeFile keeps staging names longer than 30 chars (#36)', () async {
    const fileName = 'a-quite-long-file-name-that-exceeds-thirty-chars.txt';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pluginChannel =
        MethodChannel('design.codeux.file_picker_writable');
    const pathProviderChannel =
        MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      pluginChannel,
      (call) async => <String, String>{
        'path': '/tmp/staged.txt',
        'identifier': 'id',
        'persistable': 'false',
        'uri': 'file:///tmp/staged.txt',
        'fileName': fileName,
      },
    );
    messenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => Directory.systemTemp.path,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(pluginChannel, null);
      messenger.setMockMethodCallHandler(pathProviderChannel, null);
    });
    String? stagedName;
    await FilePickerWritable().writeFile(
      identifier: 'id',
      fileName: fileName,
      writer: (file) async {
        stagedName = file.uri.pathSegments.last;
      },
    );
    expect(stagedName, fileName);
  });
}
