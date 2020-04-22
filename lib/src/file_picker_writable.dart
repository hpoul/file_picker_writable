import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FileInfo {
  FileInfo({@required this.file, @required this.identifier});

  /// temporary file which can be used for reading;
  final File file;

  /// permanent identifier which can be used for reading at a later time,
  /// or used for writing back data.
  final String identifier;

  @override
  String toString() {
    return 'FileInfo{file: $file, identifier: $identifier}';
  }
}

class FilePickerWritable {
  factory FilePickerWritable() => _instance;
  FilePickerWritable._();

  static const MethodChannel _channel =
      MethodChannel('design.codeux.file_picker_writable');
  static final FilePickerWritable _instance = FilePickerWritable._();

  Future<FileInfo> openFilePicker() async {
    final result =
        await _channel.invokeMapMethod<String, String>('openFilePicker');
    return FileInfo(
      file: File(result['path']),
      identifier: result['identifier'],
    );
  }
}
