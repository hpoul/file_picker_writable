import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

final _logger = Logger('file_picker_writable');

/// Contains information about a user selected file.
class FileInfo {
  FileInfo({
    @required this.file,
    @required this.identifier,
    @required this.uri,
    this.fileName,
  })  : assert(identifier != null),
        assert(uri != null);

  static FileInfo fromJson(Map<String, dynamic> json) => FileInfo(
        file: File(json['path'] as String),
        identifier: json['identifier'] as String,
        uri: json['uri'] as String,
        fileName: json['fileName'] as String,
      );

  static FileInfo fromJsonString(String jsonString) =>
      fromJson(json.decode(jsonString) as Map<String, dynamic>);

  /// Temporary file which can be used for reading.
  /// Can (usually) be used during the lifetime of your app instance.
  /// Should typically be only read once, if you later need to access it again
  /// use the [identifier] to read it with
  /// [FilePickerWritable.readFileWithIdentifier].
  final File file;

  /// permanent identifier which can be used for reading at a later time,
  /// or used for writing back data.
  final String identifier;

  /// Platform dependent URI.
  /// - On android either content:// or file:// url.
  /// - On iOS a file:// URL below a document provider (like iCloud).
  ///   Not a really user friendly name.
  final String uri;

  /// If available, contains the file name of the original file.
  /// (ie. most of the time the last path segment). Especially useful
  /// with android content providers which typically do not contain
  /// an actual file name in the content uri.
  ///
  /// Might be null.
  final String fileName;

  @override
  String toString() {
    return 'FileInfo{${toJson()}}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': file.path,
        'identifier': identifier,
        'uri': uri,
        'fileName': fileName,
      };

  /// Serializes this data into a json string for easy serialization.
  /// Can be read back using [fromJsonString].
  String toJsonString() => json.encode(toJson());
}

typedef OpenFileHandler = void Function(FileInfo fileInfo);

/// Singleton to accessing services of the FilePickerWritable plugin.
///
/// It can be used for:
///
/// * Open a file picker to let the user pick an existing
///   file: [openFilePicker]
/// * Open a file picker to let the user pick a location for creating
///   a new file: [openFilePickerForCreate]
/// * Write a previously picked file [writeFileWithIdentifier]
/// * (re)read a previously picked file [readFileWithIdentifier]
///
class FilePickerWritable {
  factory FilePickerWritable() => _instance;

  FilePickerWritable._() {
    _channel.setMethodCallHandler((call) async {
      _logger.fine('Got method call: {$call}');
      if (call.method == 'openFile') {
        try {
          if (_openFileHandler != null) {
            _logger.fine('calling handler. ${call.arguments.runtimeType}');
            _openFileHandler(_resultToFileInfo(
                (call.arguments as Map<dynamic, dynamic>).cast()));
            return true;
          }
          return false;
        } catch (e, stackTrace) {
          _logger.fine('Error while handling method call.', e, stackTrace);
          rethrow;
        }
      } else {
        throw PlatformException(
            code: 'MethodNotImplemented',
            message: 'method ${call.method} not implemented.');
      }
    });
    _eventChannel.receiveBroadcastStream().listen((dynamic eventArg) {
      final event = (eventArg as Map<dynamic, dynamic>).cast<String, String>();
      if (event['type'] == 'log') {
        final exception = event['exception'] ?? '';
        _logger.fine('Native Log: ${event['level']}: ${event['message']} '
            '${exception == '' ? '' : ' Exception: $exception'}');
      }
    });
  }

  static const MethodChannel _channel =
      MethodChannel('design.codeux.file_picker_writable');
  static const EventChannel _eventChannel =
      EventChannel('design.codeux.file_picker_writable/events');
  static final FilePickerWritable _instance = FilePickerWritable._();

  OpenFileHandler _openFileHandler;

  void init({@required OpenFileHandler openFileHandler}) {
    _openFileHandler = openFileHandler;
    _channel.invokeMethod<void>('init');
  }

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

  /// Reads the file previously picked by the user.
  /// Expects a [FileInfo.identifier] string for [identifier].
  Future<FileInfo> readFileWithIdentifier(String identifier) async {
    _logger.finest('readFileWithIdentifier()');
    final result = await _channel.invokeMapMethod<String, String>(
        'readFileWithIdentifier', {'identifier': identifier});
    return _resultToFileInfo(result);
  }

  /// Writes the file previously picked by the user.
  /// Expects a [FileInfo.identifier] string for [identifier].
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
      fileName: result['fileName'],
    );
  }
}
