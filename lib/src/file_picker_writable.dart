import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

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
      try {
        if (call.method == 'openFile') {
          await _filePickerState._fireFileInfoHandlers(_resultToFileInfo(
              (call.arguments as Map<dynamic, dynamic>).cast()));
          return true;
        } else if (call.method == 'handleUri') {
          _filePickerState
              ._fireUriHandlers(Uri.parse(call.arguments as String));
          return true;
        } else {
          throw PlatformException(
              code: 'MethodNotImplemented',
              message: 'method ${call.method} not implemented.');
        }
      } catch (e, stackTrace) {
        _logger.fine('Error while handling method call.', e, stackTrace);
        rethrow;
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

  final _filePickerState = FilePickerState();

  FilePickerState init() {
    _channel.invokeMethod<void>('init');
    return _filePickerState;
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

typedef FileInfoHandler = FutureOr<bool> Function(FileInfo fileInfo);
typedef UriHandler = bool Function(Uri uri);

class FilePickerState {
  FileInfo _fileInfo;
  Uri _uri;

  final List<UriHandler> _uriHandlers = [];
  final List<FileInfoHandler> _fileInfoHandler = [];

//  void init() {
//    FilePickerWritable().init(openFileHandler: (fileInfo) {
//      _fireFileInfoHandlers(fileInfo);
//    }, uriHandler: (uri) {
//      _fireUriHandlers(uri);
//    });
//  }

  Future<void> _fireFileInfoHandlers(FileInfo fileInfo) async {
    for (final handler in _fileInfoHandler) {
      if (await handler(fileInfo)) {
        // handled.
        return;
      }
    }
    _fileInfo = fileInfo;
  }

  final _fileInfoLock = Lock();

  void registerFileInfoHandler(FileInfoHandler fileInfoHandler) {
    if (_fileInfo != null) {
      _fileInfoLock.synchronized(() async {
        if (_fileInfo != null) {
          if (await fileInfoHandler(_fileInfo)) {
            _fileInfo = null;
          }
        }
      });
    }
    _fileInfoHandler.add(fileInfoHandler);
  }

  void removeFileInfoHandler(FileInfoHandler fileInfoHandler) {
    _fileInfoHandler.remove(fileInfoHandler);
  }

  void _fireUriHandlers(Uri uri) {
    for (final handler in _uriHandlers.reversed) {
      if (handler(uri)) {
        // handled.
        return;
      }
    }
    _uri = uri;
  }

  void registerUriHandler(UriHandler uriHandler) {
    if (_uri != null) {
      if (uriHandler(_uri)) {
        _uri = null;
      }
    }
    _uriHandlers.add(uriHandler);
  }

  void removeUriHandler(UriHandler uriHandler) {
    _uriHandlers.remove(uriHandler);
  }
}
