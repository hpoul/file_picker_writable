import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

final _logger = Logger('file_picker_writable');

class FileInfo {
  FileInfo({
    @required this.file,
    @required this.identifier,
    @required this.uri,
  })  : assert(identifier != null),
        assert(uri != null);

  static FileInfo fromJson(Map<String, dynamic> json) => FileInfo(
        file: File(json['path'] as String),
        identifier: json['identifier'] as String,
        uri: json['uri'] as String,
      );

  /// temporary file which can be used for reading;
  final File file;

  /// permanent identifier which can be used for reading at a later time,
  /// or used for writing back data.
  final String identifier;

  final String uri;

  @override
  String toString() {
    return 'FileInfo{${toJson()}}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': file.path,
        'identifier': identifier,
        'uri': uri,
      };
}

class FilePickerWritable {
  factory FilePickerWritable() => _instance;
  FilePickerWritable._();

  static const MethodChannel _channel =
      MethodChannel('design.codeux.file_picker_writable');
  static final FilePickerWritable _instance = FilePickerWritable._();

  Future<FileInfo> openFilePicker() async {
    _logger.finest('openFilePicker()');
    final result =
        await _channel.invokeMapMethod<String, String>('openFilePicker');
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled file picker.');
      return null;
    }
    return _resultToFileInfo(result);
  }

  Future<FileInfo> openFilePickerForCreate(File file) async {
    _logger.finest('openFilePickerForCreate($file)');
    final result = await _channel.invokeMapMethod<String, String>(
        'openFilePickerForCreate', {'path': file.absolute.path});
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled file picker.');
      return null;
    }
    return _resultToFileInfo(result);
  }

  Future<FileInfo> readFileWithIdentifier(String identifier) async {
    _logger.finest('readFileWithIdentifier()');
    final result = await _channel.invokeMapMethod<String, String>(
        'readFileWithIdentifier', {'identifier': identifier});
    return _resultToFileInfo(result);
  }

  Future<FileInfo> writeFileWithIdentifier(String identifier, File file) async {
    _logger.finest('writeFileWithIdentifier(file: $file)');
    final result = await _channel
        .invokeMapMethod<String, String>('writeFileWithIdentifier', {
      'identifier': identifier,
      'path': file.absolute.path,
    });
    return _resultToFileInfo(result);
  }

  FileInfo _resultToFileInfo(Map<String, String> result) {
    assert(result != null);
    return FileInfo(
      file: File(result['path']),
      identifier: result['identifier'],
      uri: result['uri'],
    );
  }
}
