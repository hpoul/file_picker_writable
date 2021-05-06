import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker_writable/src/event_handling.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

final _logger = Logger('file_picker_writable');

/// Contains information about a user-selected filesystem entity, e.g. a
/// [FileInfo] or [DirectoryInfo].
abstract class EntityInfo {
  EntityInfo({
    required this.identifier,
    required this.persistable,
    required this.uri,
    this.fileName,
  });

  EntityInfo.fromJson(Map<String, dynamic> json)
      : this(
          identifier: json['identifier'] as String,
          persistable: (json['persistable'] as String?) == 'true',
          uri: json['uri'] as String,
          fileName: json['fileName'] as String?,
        );

  EntityInfo.fromJsonString(String jsonString)
      : this.fromJson(json.decode(jsonString) as Map<String, dynamic>);

  /// Identifier which can be used for accessing at a later time, or, for files,
  /// used for writing back data. See [persistable] for details on the valid
  /// lifetime of the identifier.
  final String identifier;

  /// Indicates whether [identifier] is persistable. When true, it is safe to
  /// retain this identifier for access at any later time.
  ///
  /// When false, you cannot assume that access will be granted in the future.
  /// In particular, for files received from outside the app, the identifier may
  /// only be valid until the [FileOpenHandler] returns.
  final bool persistable;

  /// Platform-dependent URI.
  /// - On Android either content:// or file:// url.
  /// - On iOS a file:// URL below a document provider (like iCloud).
  ///   Not a really user friendly name.
  final String uri;

  /// If available, contains the name of the original file or directory (i.e.
  /// most of the time the last path segment). Especially useful with Android
  /// content providers which typically do not contain an actual file name in
  /// the content URI.
  final String? fileName;

  @override
  String toString() {
    return 'FileInfo{${toJson()}}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'identifier': identifier,
        'persistable': persistable.toString(),
        'uri': uri,
        'fileName': fileName,
      };

  /// Serializes this data into a json string for easy serialization.
  /// Can be read back using [fromJsonString].
  String toJsonString() => json.encode(toJson());
}

class FileInfo extends EntityInfo {
  FileInfo({
    required String identifier,
    required bool persistable,
    required String uri,
    String? fileName,
  }) : super(
          identifier: identifier,
          persistable: persistable,
          uri: uri,
          fileName: fileName,
        );

  FileInfo.fromJson(Map<String, dynamic> json) : super.fromJson(json);
  FileInfo.fromJsonString(String jsonString) : super.fromJsonString(jsonString);
}

class DirectoryInfo extends EntityInfo {
  DirectoryInfo({
    required String identifier,
    required bool persistable,
    required String uri,
    String? fileName,
  }) : super(
          identifier: identifier,
          persistable: persistable,
          uri: uri,
          fileName: fileName,
        );

  DirectoryInfo.fromJson(Map<String, dynamic> json) : super.fromJson(json);
  DirectoryInfo.fromJsonString(String jsonString)
      : super.fromJsonString(jsonString);
}

typedef FileReader<T> = Future<T> Function(FileInfo fileInfo, File file);

/// Singleton to accessing services of the FilePickerWritable plugin.
///
/// It can be used for:
///
/// * Open a file picker to let the user pick an existing
///   file: [openFile]
/// * Open a file picker to let the user pick a location for creating
///   a new file: [openFileForCreate]
/// * Write a previously picked file [writeFileWithIdentifier]
/// * (re)read a previously picked file [readFile]
///
class FilePickerWritable {
  factory FilePickerWritable() => _instance;

  FilePickerWritable._() {
    _channel.setMethodCallHandler((call) async {
      _logger.fine('Got method call: {$call}');
      try {
        if (call.method == 'openFile') {
          final result =
              (call.arguments as Map<dynamic, dynamic>).cast<String, String>();
          final fileInfo = FileInfo.fromJson(result);
          final file = _resultToFile(result);
          await _filePickerState._fireFileOpenHandlers(fileInfo, file);
          return true;
        } else if (call.method == 'handleUri') {
          await _filePickerState
              ._fireUriHandlers(Uri.parse(call.arguments as String));
          return true;
        } else if (call.method == 'handleError') {
          await _filePickerState._fireErrorEvent(
              ErrorEvent.fromJson(call.arguments as Map<dynamic, dynamic>));
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

  @Deprecated('use [openFile] instead.')
  Future<FileInfo?> openFilePicker() async {
    _logger.finest('openFilePicker()');
    final result =
        await _channel.invokeMapMethod<String, String>('openFilePicker');
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled file picker.');
      return null;
    }
    return FileInfo.fromJson(result);
  }

  /// Use [openFileForCreate] instead.
  @Deprecated('Use [openFileForCreate] instead.')
  Future<FileInfo?> openFilePickerForCreate(File file) async {
    _logger.finest('openFilePickerForCreate($file)');
    final result = await _channel.invokeMapMethod<String, String>(
        'openFilePickerForCreate', {'path': file.absolute.path});
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled file picker.');
      return null;
    }
    return FileInfo.fromJson(result);
  }

  /// Shows a file picker so the user can select a file and calls [reader]
  /// afterwards.
  Future<T?> openFile<T>(FileReader<T> reader) async {
    _logger.finest('openFilePicker()');
    final result =
        await _channel.invokeMapMethod<String, String>('openFilePicker');
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled file picker.');
      return null;
    }
    final fileInfo = FileInfo.fromJson(result);
    final file = _resultToFile(result);
    try {
      return await reader(fileInfo, file);
    } finally {
      _unawaited(file.delete());
    }
  }

  /// Opens a file picker for the user to create a file.
  /// It suggests an [fileName] file name and creates a file with the
  /// contents written to the temp file by [writer].
  ///
  /// Will return a [FileInfo] which allows future access to the file or
  /// `null` if the user cancelled the file picker.
  Future<FileInfo?> openFileForCreate({
    required String fileName,
    required Future<void> Function(File tempFile) writer,
  }) async {
    _logger.finest('openFilePickerForCreate($fileName)');
    return _createFileInNewTempDirectory(fileName, (tempFile) async {
      await writer(tempFile);
      final result = await _channel.invokeMapMethod<String, String>(
          'openFilePickerForCreate', {'path': tempFile.absolute.path});
      if (result == null) {
        // User cancelled.
        _logger.finer('User cancelled file picker.');
        return null;
      }
      return FileInfo.fromJson(result);
    });
  }

  /// See if the the directory picker and directory tree access is supported on
  /// the current platform. If this returns `false` then [openDirectory],
  /// [getDirectory], and [resolveRelativePath] will fail with an exception.
  Future<bool> isDirectoryAccessSupported() async {
    _logger.finest('isDirectoryAccessSupported()');
    final result =
        await _channel.invokeMethod<bool>('isDirectoryAccessSupported');
    if (result == null) {
      throw StateError('Error while checking if directory access is supported');
    }
    return result;
  }

  /// Shows a directory picker so the user can select a directory.
  ///
  /// [initialDirUri] is the URI indicating where the picker should start by
  /// default. This is only honored on a best-effort basis and even then is not
  /// supported on all systems. It can be a [FileInfo.uri] or a
  /// [DirectoryInfo.uri].
  ///
  /// An exception will be thrown if invoked on a system that does not support
  /// directory access, i.e. if [isDirectoryAccessSupported] returns `false`.
  Future<DirectoryInfo?> openDirectory({String? initialDirUri}) async {
    _logger.finest('openDirectoryPicker()');
    final result = await _channel.invokeMapMethod<String, String>(
        'openDirectoryPicker', {'initialDirUri': initialDirUri});
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled directory picker.');
      return null;
    }
    return DirectoryInfo.fromJson(result);
  }

  /// Reads the file previously picked by the user.
  /// Expects a [FileInfo.identifier] string for [identifier].
  ///
  Future<T> readFile<T>({
    required String identifier,
    required FileReader<T> reader,
  }) async {
    _logger.finest('readFile()');
    final result = await _channel.invokeMapMethod<String, String>(
        'readFileWithIdentifier', {'identifier': identifier});
    if (result == null) {
      throw StateError('Error while reading file with identifier $identifier');
    }
    final fileInfo = FileInfo.fromJson(result);
    final file = _resultToFile(result);
    try {
      return await reader(fileInfo, file);
    } catch (e, stackTrace) {
      _logger.warning('Error while calling reader method.', e, stackTrace);
      rethrow;
    } finally {
      _unawaited(file.delete());
    }
  }

  /// Get info for the immediate parent directory of [fileIdentifier], making
  /// use of access permissions to [rootIdentifier] some arbitrary number of
  /// levels higher in the hierarchy.
  ///
  /// [rootIdentifier] should be a [DirectoryInfo.identifier] obtained from
  /// [pickDirectory]. [fileIdentifier] should be a [FileInfo.identifier].
  ///
  /// An exception will be thrown if invoked on a system that does not support
  /// directory access, i.e. if [isDirectoryAccessSupported] returns `false`.
  Future<DirectoryInfo> getDirectory({
    required String rootIdentifier,
    required String fileIdentifier,
  }) async {
    _logger.finest('getDirectory()');
    final result = await _channel.invokeMapMethod<String, String>(
        'getDirectory',
        {'rootIdentifier': rootIdentifier, 'fileIdentifier': fileIdentifier});
    if (result == null) {
      throw StateError(
          'Error while getting directory of $fileIdentifier relative to $rootIdentifier');
    }
    return DirectoryInfo.fromJson(result);
  }

  /// Get info for the entity identified by [relativePath] starting from
  /// [directoryIdentifier].
  ///
  /// [directoryIdentifier] should be a [DirectoryInfo.identifier] obtained from
  /// [pickDirectory] or [getDirectory].
  ///
  /// An exception will be thrown if invoked on a system that does not support
  /// directory access, i.e. if [isDirectoryAccessSupported] returns `false`.
  Future<EntityInfo> resolveRelativePath({
    required String directoryIdentifier,
    required String relativePath,
  }) async {
    _logger.finest('resolveRelativePath()');
    final result = await _channel.invokeMapMethod<String, String>(
        'resolveRelativePath', {
      'directoryIdentifier': directoryIdentifier,
      'relativePath': relativePath
    });
    if (result == null) {
      throw StateError(
          'Error while resolving relative path $relativePath from directory $directoryIdentifier');
    }
    return result['isDirectory'] == 'true'
        ? DirectoryInfo.fromJson(result)
        : FileInfo.fromJson(result);
  }

  /// Writes the file previously picked by the user.
  /// Expects a [FileInfo.identifier] string for [identifier].
  Future<FileInfo> writeFileWithIdentifier(String identifier, File file) async {
    _logger.finest('writeFileWithIdentifier(file: $file)');
    final result = await (_channel
        .invokeMapMethod<String, String>('writeFileWithIdentifier', {
      'identifier': identifier,
      'path': file.absolute.path,
    }) as FutureOr<Map<String, String>>);
    return FileInfo.fromJson(result);
  }

  /// Writes data to a file previously picked by the user.
  /// Expects a [FileInfo.identifier] string for [identifier].
  /// The [writer] will receive a file in a temporary directory named
  /// [fileName] (if not given will be called `temp`).
  /// The temporary directory will be deleted when writing is complete.
  Future<FileInfo> writeFile({
    required String identifier,
    String fileName = 'temp',
    required Future<void> Function(File file) writer,
  }) async {
    _logger.finest('writeFileWithIdentifier()');
    final result =
        await _createFileInNewTempDirectory(fileName, (tempFile) async {
      await writer(tempFile);
      final result = await _channel
          .invokeMapMethod<String, String>('writeFileWithIdentifier', {
        'identifier': identifier,
        'path': tempFile.absolute.path,
      });
      return result!;
    });
    return FileInfo.fromJson(result);
  }

  /// Dispose of a persistable identifier, removing it from your app's list of
  /// accessible files. Afterwards, you will need the user to re-pick the file
  /// in order to access it again.
  ///
  /// Some platforms (Android) limit how many identifiers your app can persist
  /// at once. Use this method to remove identifiers you no longer need.
  Future<void> disposeIdentifier(String identifier) async {
    _logger.finest('disposeIdentifier()');
    return _channel
        .invokeMethod<void>('disposeIdentifier', {'identifier': identifier});
  }

  File _resultToFile(Map<String, String> result) {
    return File(result['path']!);
  }

  Future<T> _createFileInNewTempDirectory<T>(
      String baseName, Future<T> Function(File tempFile) callback) async {
    if (baseName.length > 30) {
      baseName = baseName.substring(0, 30);
    }
    final tempDirBase = await getTemporaryDirectory();

    final tempDir = await tempDirBase.createTemp('file_picker_writable');
    await tempDir.create(recursive: true);
    final tempFile = File(path.join(
      tempDir.path,
      baseName,
    ));
    try {
      return await callback(tempFile);
    } finally {
      _unawaited(tempDir
          .delete(recursive: true)
          .catchError((dynamic error, StackTrace stackTrace) {
        _logger.warning('Error while deleting temp dir.', error, stackTrace);
      }));
    }
  }
}

/// State of the [FilePickerWritable] plugin to add listeners for events
/// like file opening and error handling.
class FilePickerState {
  final List<FilePickerEventHandler> _eventHandlers = [];
  FilePickerEvent? _pendingEvent;

//  void init() {
//    FilePickerWritable().init(openFileHandler: (fileInfo) {
//      _fireFileInfoHandlers(fileInfo);
//    }, uriHandler: (uri) {
//      _fireUriHandlers(uri);
//    });
//  }

  Future<bool> _fireFileOpenHandlers(FileInfo fileInfo, File file) async {
    return await _fireEvent(FilePickerEventOpen(fileInfo, file));
  }

  Future<bool> _fireErrorEvent(ErrorEvent errorEvent) async {
    _logger.fine('Firing error event for $errorEvent');
    return await _fireEvent(
      FilePickerEventLambda(
          (handler) => handler.handleErrorEvent(errorEvent), () async {},
          debugMessage: 'error: $errorEvent'),
    );
  }

  Future<bool> _fireEvent(FilePickerEvent event) async {
    try {
      for (final handler in _eventHandlers) {
        if (await event.dispatch(handler)) {
          _unawaited(event.dispose());
          return true;
        }
      }
      if (_pendingEvent != null) {
        _unawaited(_pendingEvent?.dispose());
      }
      _pendingEvent = event;
      return false;
    } catch (e, stackTrace) {
      _logger.severe('Error while dispatching ${event.debugMessage} event.', e,
          stackTrace);
      rethrow;
    }
  }

  final _pendingEventLock = Lock();

  void _registerFilePickerEventHandler(FilePickerEventHandler handler) {
    if (_pendingEvent != null) {
      _pendingEventLock.synchronized(() async {
        if (_pendingEvent != null) {
          if (await _pendingEvent!.dispatch(handler)) {
            _pendingEvent = null;
          }
        }
      });
    }
    _eventHandlers.add(handler);
  }

  /// deprecated: use [registerFileOpenHandler] instead.
  @Deprecated('use [registerFileOpenHandler] instead.')
  void registerFileInfoHandler(FileInfoHandler fileInfoHandler) {
    _registerFilePickerEventHandler(
        FilePickerEventHandlerLambda(fileInfoHandler: fileInfoHandler));
  }

  @Deprecated('use [removeFileOpenHandler] instead.')
  bool removeFileInfoHandler(FileInfoHandler fileInfoHandler) => _eventHandlers
      .remove(FilePickerEventHandlerLambda(fileInfoHandler: fileInfoHandler));

  /// Registers the [fileOpenHandler] to be called when the app is launched
  /// with a file it should open.
  /// The fileOpenHandler will receive a file object which will be deleted
  /// once it returns.
  void registerFileOpenHandler(FileOpenHandler fileOpenHandler) =>
      _registerFilePickerEventHandler(
          FilePickerEventHandlerLambda(fileOpenHandler: fileOpenHandler));

  /// Removes the given [fileOpenHandler].
  bool removeFileOpenHandler(FileOpenHandler fileOpenHandler) => _eventHandlers
      .remove(FilePickerEventHandlerLambda(fileOpenHandler: fileOpenHandler));

  Future<bool> _fireUriHandlers(Uri uri) => _fireEvent(FilePickerEventLambda(
      (handler) => handler.handleUri(uri), () => null,
      debugMessage: 'handleUri($uri)'));

  void registerUriHandler(UriHandler uriHandler) =>
      _registerFilePickerEventHandler(
          FilePickerEventHandlerLambda(uriHandler: uriHandler));

  void removeUriHandler(UriHandler uriHandler) => _eventHandlers
      .remove(FilePickerEventHandlerLambda(uriHandler: uriHandler));

  /// Registers [errorEventHandler] which will be called when an error
  /// occurs during open handlers, when it can't be delivered otherwise.
  /// (ie. an error during initialisation of openURLs/File Open)
  void registerErrorEventHandler(ErrorEventHandler errorEventHandler) =>
      _registerFilePickerEventHandler(
          FilePickerEventHandlerLambda(errorEventHandler: errorEventHandler));

  void removeErrorEventHandler(ErrorEventHandler errorEventHandler) =>
      _eventHandlers.remove(
          FilePickerEventHandlerLambda(errorEventHandler: errorEventHandler));
}

void _unawaited(Future<dynamic>? future) {}
