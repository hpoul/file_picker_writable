import 'package:file_picker_writable/file_picker_writable.dart';
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
}
