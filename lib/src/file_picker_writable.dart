import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker_writable/src/event_handling.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart' show experimental;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

final _logger = Logger('file_picker_writable');

/// Contains information about a user selected file.
class FileInfo {
  FileInfo({
    required this.identifier,
    required this.persistable,
    required this.uri,
    this.fileName,
  });

  static FileInfo fromJson(Map<String, dynamic> json) => FileInfo(
    identifier: json['identifier'] as String,
    persistable: (json['persistable'] as String?) == 'true',
    uri: json['uri'] as String,
    fileName: json['fileName'] as String?,
  );

  static FileInfo fromJsonString(String jsonString) =>
      fromJson(json.decode(jsonString) as Map<String, dynamic>);

  /// Identifier which can be used for reading at a later time, or used for
  /// writing back data. See [persistable] for details on the valid lifetime of
  /// the identifier.
  final String identifier;

  /// Indicates whether [identifier] is persistable. When true, it is safe to
  /// retain this identifier for access at any later time.
  ///
  /// When false, you cannot assume that access will be granted in the
  /// future. In particular, for files received from outside the app, the
  /// identifier may only be valid until the [FileOpenHandler] returns.
  final bool persistable;

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

/// A native access scope held for one identifier, from
/// [FilePickerWritable.acquire]. Hand it back to
/// [FilePickerWritable.release] exactly once when done.
///
/// Error kinds, carried as [PlatformException.code] with the native
/// domain and code in [PlatformException.details] where available:
/// - `permission-lost`: the grant was revoked, the media detached, the
///   scope start was refused, or a bookmark no longer resolves.
/// - `not-found`: the grant is held but the file or folder is gone.
/// - `scope-closed`: a released scope was used (verbs that take a scope).
///
/// Anything else stays loud under its own native code.
@experimental
class AcquiredScope {
  AcquiredScope({
    required this.id,
    required this.identifier,
    required this.repaired,
    required this.path,
    required this.displayName,
  });

  static AcquiredScope _fromResult(Map<String, Object?> result) =>
      AcquiredScope(
        id: result['id']! as String,
        identifier: result['identifier']! as String,
        repaired: result['repaired']! as bool,
        path: result['path'] as String?,
        displayName: result['displayName']! as String,
      );

  /// Opaque token for this hold, passed back to
  /// [FilePickerWritable.release].
  final String id;

  /// The identifier to use from now on. Equal to the acquired identifier
  /// unless [repaired].
  final String identifier;

  /// True when the acquired identifier was stale and [identifier] is a
  /// fresh replacement. The app MUST then persist [identifier] in place
  /// of the old one. The old identifier keeps working until then.
  final bool repaired;

  /// A usable file system path while the scope is held (iOS), or null
  /// where none exists (Android content URIs). Branch on null, never on
  /// the platform.
  final String? path;

  /// The file or folder name, re-read on every acquire.
  final String displayName;

  @override
  String toString() =>
      'AcquiredScope{id: $id, repaired: $repaired, '
      'path: $path, displayName: $displayName}';
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
          final result = (call.arguments as Map<dynamic, dynamic>)
              .cast<String, String>();
          final fileInfo = _resultToFileInfo(result);
          final file = _resultToFile(result);
          await _filePickerState._fireFileOpenHandlers(fileInfo, file);
          return true;
        } else if (call.method == 'handleUri') {
          await _filePickerState._fireUriHandlers(
            Uri.parse(call.arguments as String),
          );
          return true;
        } else if (call.method == 'handleError') {
          await _filePickerState._fireErrorEvent(
            ErrorEvent.fromJson(call.arguments as Map<dynamic, dynamic>),
          );
        } else if (call.method == 'handleDrop') {
          final files = ((call.arguments as Map)['files'] as List).map(
            (dynamic f) => (f as Map).cast<String, String>(),
          );
          final items = files
              .map(
                (result) => DropItem(
                  fileInfo: _resultToFileInfo(result),
                  file: _resultToFile(result),
                ),
              )
              .toList();
          await _filePickerState._fireDropHandlers(DropEvent(items));
          return true;
        } else if (call.method == 'dragEntered') {
          _filePickerState._fireDropHover(true);
          return true;
        } else if (call.method == 'dragExited') {
          _filePickerState._fireDropHover(false);
          return true;
        } else {
          throw PlatformException(
            code: 'MethodNotImplemented',
            message: 'method ${call.method} not implemented.',
          );
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
        _logger.fine(
          'Native Log: ${event['level']}: ${event['message']} '
          '${exception == '' ? '' : ' Exception: $exception'}',
        );
      }
    });
  }

  static const MethodChannel _channel = MethodChannel(
    'design.codeux.file_picker_writable',
  );
  static const EventChannel _eventChannel = EventChannel(
    'design.codeux.file_picker_writable/events',
  );
  static final FilePickerWritable _instance = FilePickerWritable._();

  final _filePickerState = FilePickerState();

  /// Tokens acquired by this isolate and not yet released.
  final Set<String> _liveScopeIds = {};

  /// Identifies this Dart isolate to the native scope registry. A new
  /// session (e.g. after a hot restart) makes native balance every hold
  /// left by the previous one on its first acquire.
  final String _scopeSession =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  FilePickerState init() {
    _channel.invokeMethod<void>('init');
    return _filePickerState;
  }

  @Deprecated('use [openFile] instead.')
  Future<FileInfo?> openFilePicker() async {
    _logger.finest('openFilePicker()');
    final result = await _channel.invokeMapMethod<String, String>(
      'openFilePicker',
    );
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled file picker.');
      return null;
    }
    return _resultToFileInfo(result);
  }

  /// Use [openFileForCreate] instead.
  @Deprecated('Use [openFileForCreate] instead.')
  Future<FileInfo?> openFilePickerForCreate(File file) async {
    _logger.finest('openFilePickerForCreate($file)');
    final result = await _channel.invokeMapMethod<String, String>(
      'openFilePickerForCreate',
      {'path': file.absolute.path},
    );
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled file picker.');
      return null;
    }
    return _resultToFileInfo(result);
  }

  /// Shows a file picker so the user can select a file and calls [reader]
  /// afterwards.
  Future<T?> openFile<T>(FileReader<T> reader) async {
    _logger.finest('openFilePicker()');
    final result = await _channel.invokeMapMethod<String, String>(
      'openFilePicker',
    );
    if (result == null) {
      // User cancelled.
      _logger.finer('User cancelled file picker.');
      return null;
    }
    final fileInfo = _resultToFileInfo(result);
    final file = _resultToFile(result);
    try {
      return await reader(fileInfo, file);
    } finally {
      unawaited(file.delete());
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
        'openFilePickerForCreate',
        {'path': tempFile.absolute.path},
      );
      if (result == null) {
        // User cancelled.
        _logger.finer('User cancelled file picker.');
        return null;
      }
      return _resultToFileInfo(result);
    });
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
      'readFileWithIdentifier',
      {'identifier': identifier},
    );
    if (result == null) {
      throw StateError('Error while reading file with identifier $identifier');
    }
    final fileInfo = _resultToFileInfo(result);
    final file = _resultToFile(result);
    try {
      return await reader(fileInfo, file);
    } catch (e, stackTrace) {
      _logger.warning('Error while calling reader method.', e, stackTrace);
      rethrow;
    } finally {
      unawaited(file.delete());
    }
  }

  /// Writes the file previously picked by the user.
  /// Expects a [FileInfo.identifier] string for [identifier].
  Future<FileInfo> writeFileWithIdentifier(String identifier, File file) async {
    _logger.finest('writeFileWithIdentifier(file: $file)');
    final result = await _channel.invokeMapMethod<String, String>(
      'writeFileWithIdentifier',
      {'identifier': identifier, 'path': file.absolute.path},
    );
    if (result == null) {
      throw StateError('Got null response for writeFileWithIdentifier');
    }
    return _resultToFileInfo(result);
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
    final result = await _createFileInNewTempDirectory(fileName, (
      tempFile,
    ) async {
      await writer(tempFile);
      final result = await _channel.invokeMapMethod<String, String>(
        'writeFileWithIdentifier',
        {'identifier': identifier, 'path': tempFile.absolute.path},
      );
      return result!;
    });
    return _resultToFileInfo(result);
  }

  /// Dispose of a persistable identifier, removing it from your app's list of
  /// accessible files. Afterwards, you will need the user to re-pick the file
  /// in order to access it again.
  ///
  /// Some platforms (Android) limit how many identifiers your app can persist
  /// at once. Use this method to remove identifiers you no longer need.
  Future<void> disposeIdentifier(String identifier) async {
    _logger.finest('disposeIdentifier()');
    return _channel.invokeMethod<void>('disposeIdentifier', {
      'identifier': identifier,
    });
  }

  /// Dispose of all identifiers persisted for your app. Afterwards, you will
  /// need the user to re-pick any files in order to access them.
  ///
  /// Some platforms (Android) limit how many identifiers your app can persist
  /// at once. Use this method to ensure that all identifiers are disposed, even
  /// in the case where e.g. you have lost track of an identifier and so cannot
  /// call [disposeIdentifier] on it.
  Future<void> disposeAllIdentifiers() async {
    _logger.finest('disposeAllIdentifiers()');
    return _channel.invokeMethod<void>('disposeAllIdentifiers');
  }

  /// Shows a picker for a directory. Returns null if the user cancelled.
  ///
  /// The grant is persisted (Android) or bookmarked (iOS), so the returned
  /// [FileInfo.identifier] feeds [acquire] across relaunches without
  /// re-picking. [FileInfo.fileName] is the picked folder's display label.
  /// No bytes are copied.
  ///
  /// Android and iOS only; throws [UnsupportedError] elsewhere.
  @experimental
  Future<FileInfo?> openDirectory() async {
    _logger.finest('openDirectory()');
    _requireScopePlatform('openDirectory');
    final result = await _channel.invokeMapMethod<String, String>(
      'openDirectory',
    );
    if (result == null) {
      _logger.finer('User cancelled directory picker.');
      return null;
    }
    return _resultToFileInfo(result);
  }

  /// Acquires native access scope for [identifier] until [release].
  ///
  /// Each call returns its own [AcquiredScope.id]; native refcounts per
  /// file, so acquire, acquire, release still holds. A stale identifier is
  /// repaired: [AcquiredScope.repaired] is true and
  /// [AcquiredScope.identifier] is the replacement the app MUST persist.
  ///
  /// On iOS this holds the security scope. On Android, where persisted
  /// grants need no ceremony, it checks the grant is still held. Neither
  /// copies the file. Failures are [PlatformException]s with the kinds
  /// listed on [AcquiredScope].
  ///
  /// Android and iOS only; throws [UnsupportedError] elsewhere.
  @experimental
  Future<AcquiredScope> acquire({required String identifier}) async {
    _logger.finest('acquire()');
    _requireScopePlatform('acquire');
    final result = await _channel.invokeMapMethod<String, Object?>('acquire', {
      'identifier': identifier,
      'session': _scopeSession,
    });
    if (result == null) {
      throw StateError('Got null response for acquire');
    }
    final scope = AcquiredScope._fromResult(result);
    _liveScopeIds.add(scope.id);
    return scope;
  }

  /// Releases a scope from [acquire]. Idempotent: releasing a scope twice
  /// is a no-op, never an error.
  @experimental
  Future<void> release(AcquiredScope scope) async {
    _logger.finest('release()');
    if (!_liveScopeIds.remove(scope.id)) {
      return;
    }
    await _channel.invokeMethod<void>('release', {'id': scope.id});
  }

  void _requireScopePlatform(String verb) {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      throw UnsupportedError(
        '$verb is not supported on $defaultTargetPlatform.',
      );
    }
  }

  FileInfo _resultToFileInfo(Map<String, String> result) {
    return FileInfo(
      identifier: result['identifier']!,
      persistable: result['persistable'] == 'true',
      uri: result['uri']!,
      fileName: result['fileName'],
    );
  }

  File _resultToFile(Map<String, String> result) {
    return File(result['path']!);
  }

  Future<T> _createFileInNewTempDirectory<T>(
    String baseName,
    Future<T> Function(File tempFile) callback,
  ) async {
    final tempDirBase = await getTemporaryDirectory();

    final tempDir = await tempDirBase.createTemp('file_picker_writable');
    await tempDir.create(recursive: true);
    final tempFile = File(path.join(tempDir.path, baseName));
    try {
      return await callback(tempFile);
    } finally {
      unawaited(
        (() async {
          try {
            await tempDir.delete(recursive: true);
          } catch (error, stackTrace) {
            _logger.warning(
              'Error while deleting temp dir.',
              error,
              stackTrace,
            );
          }
        })(),
      );
    }
  }
}

/// State of the [FilePickerWritable] plugin to add listeners for events
/// like file opening and error handling.
class FilePickerState {
  final List<FilePickerEventHandler> _eventHandlers = [];

  /// Events that arrived while no handler accepted them, in arrival order.
  /// Each registration offers the queued events, oldest first, to the new
  /// handler; handled ones are disposed and dropped from the queue.
  final List<FilePickerEvent> _pendingEvents = [];

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
        (handler) => handler.handleErrorEvent(errorEvent),
        () async {},
        debugMessage: 'error: $errorEvent',
      ),
    );
  }

  Future<bool> _fireEvent(FilePickerEvent event) async {
    try {
      for (final handler in _eventHandlers.toList()) {
        if (await event.dispatch(handler)) {
          unawaited(event.dispose());
          return true;
        }
      }
      _pendingEvents.add(event);
      return false;
    } catch (e, stackTrace) {
      _logger.severe(
        'Error while dispatching ${event.debugMessage} event.',
        e,
        stackTrace,
      );
      rethrow;
    }
  }

  final _pendingEventLock = Lock();

  void _registerFilePickerEventHandler(FilePickerEventHandler handler) {
    if (_pendingEvents.isNotEmpty) {
      _pendingEventLock.synchronized(() async {
        for (final pending in _pendingEvents.toList()) {
          if (await pending.dispatch(handler)) {
            _pendingEvents.remove(pending);
            unawaited(pending.dispose());
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
      FilePickerEventHandlerLambda(fileInfoHandler: fileInfoHandler),
    );
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
        FilePickerEventHandlerLambda(fileOpenHandler: fileOpenHandler),
      );

  /// Removes the given [fileOpenHandler].
  bool removeFileOpenHandler(FileOpenHandler fileOpenHandler) => _eventHandlers
      .remove(FilePickerEventHandlerLambda(fileOpenHandler: fileOpenHandler));

  Future<bool> _fireUriHandlers(Uri uri) => _fireEvent(
    FilePickerEventLambda(
      (handler) => handler.handleUri(uri),
      () => null,
      debugMessage: 'handleUri($uri)',
    ),
  );

  void registerUriHandler(UriHandler uriHandler) =>
      _registerFilePickerEventHandler(
        FilePickerEventHandlerLambda(uriHandler: uriHandler),
      );

  void removeUriHandler(UriHandler uriHandler) => _eventHandlers.remove(
    FilePickerEventHandlerLambda(uriHandler: uriHandler),
  );

  /// Registers [errorEventHandler] which will be called when an error
  /// occurs during open handlers, when it can't be delivered otherwise.
  /// (ie. an error during initialisation of openURLs/File Open)
  void registerErrorEventHandler(ErrorEventHandler errorEventHandler) =>
      _registerFilePickerEventHandler(
        FilePickerEventHandlerLambda(errorEventHandler: errorEventHandler),
      );

  void removeErrorEventHandler(ErrorEventHandler errorEventHandler) =>
      _eventHandlers.remove(
        FilePickerEventHandlerLambda(errorEventHandler: errorEventHandler),
      );

  /// Registers [dropHandler] to be called with every file dropped onto the
  /// app window, grouped into one [DropEvent] per drag session.
  /// Temp files are deleted once the drop is handled, so copy them
  /// elsewhere first to keep them.
  /// Drops that arrive before any handler is registered wait in a queue
  /// and are delivered, oldest first, when a handler registers.
  /// Currently delivered on Android only.
  void registerDropHandler(DropHandler dropHandler) =>
      _registerFilePickerEventHandler(
        FilePickerEventHandlerLambda(dropHandler: dropHandler),
      );

  /// Removes the given [dropHandler].
  bool removeDropHandler(DropHandler dropHandler) => _eventHandlers.remove(
    FilePickerEventHandlerLambda(dropHandler: dropHandler),
  );

  Future<bool> _fireDropHandlers(DropEvent drop) =>
      _fireEvent(FilePickerEventDrop(drop));

  final List<DropHoverHandler> _dropHoverHandlers = [];

  /// Registers [hoverHandler] to be called when a drag hovers over (`true`)
  /// or leaves (`false`) the app window.
  /// Currently delivered on Android only.
  void registerDropHoverHandler(DropHoverHandler hoverHandler) {
    _dropHoverHandlers.add(hoverHandler);
  }

  /// Removes the given [hoverHandler].
  bool removeDropHoverHandler(DropHoverHandler hoverHandler) =>
      _dropHoverHandlers.remove(hoverHandler);

  void _fireDropHover(bool entered) {
    for (final handler in _dropHoverHandlers.toList()) {
      handler(entered);
    }
  }
}
