import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker_writable/src/event_handling.dart';
// dart:ffi only where it exists: a web build must never import it.
import 'package:file_picker_writable/src/fd_native_stub.dart'
    if (dart.library.ffi) 'package:file_picker_writable/src/fd_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart' show experimental;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

part 'fd_reading.dart';
part 'fd_writing.dart';

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
///   scope start was refused, or a bookmark no longer resolves. On Android
///   a detached volume is recognized for the system's own storage provider
///   (internal storage, SD card, USB), with `reason: volume-absent` in the
///   details; other providers are opaque, and a detached volume there
///   reads as `not-found`.
/// - `not-found`: the grant is held but the file or folder is gone. On iOS
///   a folder deleted in Files (moved into the provider's `.Trash`) reads
///   as gone too, with `reason: trashed` in the details.
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

/// Metadata for one direct child of a directory, from
/// [FilePickerWritable.listChildren] or [FilePickerWritable.lookupChild].
/// Listing never copies a file or touches temp storage.
@experimental
class ChildEntry {
  ChildEntry({
    required this.name,
    required String identifier,
    required this.isDirectory,
    required this.size,
    required this.lastModified,
  }) : _identifierPrefix = '',
       _identifierSuffix = identifier;

  ChildEntry._composed(
    this._identifierPrefix,
    this._identifierSuffix, {
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.lastModified,
  });

  /// [result] carries either a full `identifier` (a lookup; Android) or an
  /// `identifierSuffix` to append to the listing's shared
  /// [identifierPrefix] (an iOS listing, where the prefix is the ~2.5 KB
  /// root bookmark: sent and kept once, not once per child).
  static ChildEntry _fromResult(
    Map<Object?, Object?> result, {
    String? identifierPrefix,
  }) {
    final lastModified = result['lastModified'] as int?;
    final suffix = result['identifierSuffix'] as String?;
    final full = result['identifier'] as String?;
    if ((suffix == null) == (full == null)) {
      throw StateError(
        'A child entry needs exactly one of identifier and identifierSuffix',
      );
    }
    if (suffix != null && identifierPrefix == null) {
      throw StateError('Got an identifierSuffix without an identifierPrefix');
    }
    return ChildEntry._composed(
      suffix == null ? '' : identifierPrefix!,
      suffix ?? full!,
      name: result['name']! as String,
      isDirectory: result['isDirectory']! as bool,
      size: result['size'] as int?,
      // 0 (or less) is a provider that doesn't track it: "won't say".
      // Normalized here so the rule holds on every platform.
      lastModified: lastModified == null || lastModified <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastModified, isUtc: true),
    );
  }

  /// The child's name as the provider stores it. Names starting with `.`
  /// are ordinary names; nothing filters them.
  final String name;

  /// Opaque identifier for the child, usable wherever an identifier is
  /// taken (including [FilePickerWritable.listChildren] for a
  /// subdirectory). Never parse it, and never compare it: the same child
  /// can come back under a different identifier (a repaired root rewrites
  /// every child's, and a lookup echoes the requested spelling). It is a
  /// locator for this session; persist the picked folder's identifier and
  /// re-derive children by name.
  ///
  /// Composed on first read from a prefix shared by the whole listing, so a
  /// large listing holds the prefix once and pays for a full identifier
  /// only on the entries whose identifier is actually used.
  late final String identifier = _identifierPrefix + _identifierSuffix;

  final String _identifierPrefix;
  final String _identifierSuffix;

  final bool isDirectory;

  /// Size in bytes, or null when the provider won't say. Always null for a
  /// directory.
  final int? size;

  /// Last modification time, or null when the provider won't say (a
  /// provider reporting 0 counts as not saying).
  final DateTime? lastModified;

  @override
  String toString() =>
      'ChildEntry{name: $name, isDirectory: $isDirectory, size: $size, '
      'lastModified: $lastModified}';
}

/// One level of a directory, from [FilePickerWritable.listChildren].
@experimental
class DirectoryListing {
  DirectoryListing({
    required this.entries,
    required this.identifier,
    required this.repaired,
  });

  static DirectoryListing _fromResult(Map<String, Object?> result) {
    final identifierPrefix = result['identifierPrefix'] as String?;
    return DirectoryListing(
      entries: [
        for (final entry in result['entries']! as List<Object?>) ...[
          ChildEntry._fromResult(
            entry! as Map<Object?, Object?>,
            identifierPrefix: identifierPrefix,
          ),
        ],
      ],
      identifier: result['identifier']! as String,
      repaired: result['repaired']! as bool,
    );
  }

  /// The direct children, in the provider's order, which is unspecified.
  final List<ChildEntry> entries;

  /// The directory identifier to use from now on. Equal to the listed
  /// identifier unless [repaired].
  final String identifier;

  /// True when the listed identifier was stale and [identifier] is a
  /// fresh replacement the app MUST persist, as with
  /// [AcquiredScope.repaired].
  final bool repaired;
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
        _logger.log(
          event['level'] == 'warning' ? Level.WARNING : Level.FINE,
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
  /// Call this from the root isolate only. Native holds belong to one Dart
  /// isolate at a time, so that a hot restart can release the old isolate's
  /// holds: an acquire from a second isolate releases every hold the first
  /// one had, and native logs a warning when that happens. Helper isolates
  /// work under a scope the root acquired.
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
    // Forgotten before the channel call, on purpose: the scope is released
    // from Dart's view even if the native call fails, so a retry is the
    // no-op, never a second native release.
    if (!_liveScopeIds.remove(scope.id)) {
      return;
    }
    await _channel.invokeMethod<void>('release', {'id': scope.id});
  }

  /// Lists one level of the directory [identifier] names: metadata only,
  /// in one call, never copying a file. Recurse by passing a child's
  /// [ChildEntry.identifier] back in.
  ///
  /// Manages native scope itself for the duration of the call. A stale
  /// directory identifier is repaired like [acquire]'s: see
  /// [DirectoryListing.repaired].
  ///
  /// Failures are [PlatformException]s with the kinds listed on
  /// [AcquiredScope], plus `not-a-directory` when [identifier] resolves to
  /// something that is not a listable directory. One exception to
  /// loudness: Android's system storage provider lists a directory it
  /// cannot read (e.g. on a failing stick) as empty, so an empty listing
  /// is not proof of an empty folder.
  ///
  /// Android and iOS only; throws [UnsupportedError] elsewhere.
  @experimental
  Future<DirectoryListing> listChildren({required String identifier}) async {
    _logger.finest('listChildren()');
    _requireScopePlatform('listChildren');
    final result = await _channel.invokeMapMethod<String, Object?>(
      'listChildren',
      {'identifier': identifier},
    );
    if (result == null) {
      throw StateError('Got null response for listChildren');
    }
    return DirectoryListing._fromResult(result);
  }

  /// Looks up the child called [name] directly under the directory
  /// [identifier], without listing it. Returns null when there is no such
  /// child: absence is an answer, not an error. A gone or unreadable
  /// directory is loud, with the same kinds as [listChildren].
  ///
  /// [name] is a single leaf name: empty, `.`, `..`, or anything containing
  /// `/` or NUL throws [ArgumentError]. On Android's system storage
  /// provider matching is the file system's: case-insensitive on shared
  /// storage and FAT/exFAT sticks, which also ignore trailing dots and
  /// spaces, so `TRIP.JSON` or `trip.json ` find `trip.json`, and
  /// [ChildEntry.name] echoes the requested spelling rather than the stored
  /// one. Other providers match the exact name. Treat a hit as "that name
  /// is taken", and read stored names from [listChildren].
  ///
  /// Unlike [listChildren], a stale directory identifier is not reported
  /// here; [acquire] or [listChildren] repair it.
  ///
  /// Android and iOS only; throws [UnsupportedError] elsewhere.
  @experimental
  Future<ChildEntry?> lookupChild({
    required String identifier,
    required String name,
  }) async {
    _logger.finest('lookupChild()');
    _requireScopePlatform('lookupChild');
    _requireLeafName(name);
    final result = await _channel.invokeMapMethod<String, Object?>(
      'lookupChild',
      {'identifier': identifier, 'name': name},
    );
    if (result == null) {
      return null;
    }
    return ChildEntry._fromResult(result);
  }

  /// Opens the file [scope] holds for reading and hands its descriptor to
  /// Dart: a control call that never reads a byte. Read it with an
  /// [FdReader] in the isolate that consumes the bytes (see
  /// [ReadSession]); a session that is never wrapped is closed with
  /// [closeRead].
  ///
  /// [scope] must still be acquired (`scope-closed` otherwise), and should
  /// stay acquired until the reader closes (see [ReadHandoff.scopeToken]).
  /// The file is the one [scope] named when it was acquired: on iOS a file
  /// renamed since reads as `not-found`, so re-acquire after a listing.
  /// On Android the scope's identifier needs a persisted grant
  /// (`permission-lost` otherwise), so a file picked without one cannot be
  /// opened here.
  ///
  /// Failures are [PlatformException]s with the kinds listed on
  /// [AcquiredScope], `not-a-file` for a directory, or `errno-<n>` (the
  /// platform's own errno number) for a failed system call outside them.
  ///
  /// The descriptor is Dart's from the moment native replies: if the reply
  /// is lost (the engine shuts down mid-call), that descriptor leaks, once.
  ///
  /// Root isolate only, like [acquire]. Android and iOS only; throws
  /// [UnsupportedError] elsewhere.
  @experimental
  Future<ReadSession> openRead({required AcquiredScope scope}) async {
    _logger.finest('openRead()');
    _requireScopePlatform('openRead');
    _requireScopeLive(scope.id);
    final result = await _channel.invokeMapMethod<String, Object?>('openRead', {
      'scope': scope.id,
    });
    if (result == null) {
      throw StateError('Got null response for openRead');
    }
    return ReadSession._(
      result['fd']! as int,
      scope.id,
      seekable: result['seekable']! as bool,
      length: result['length'] as int?,
    );
  }

  /// Closes a [ReadSession] that no [FdReader] took over. Idempotent; on a
  /// session that has a reader it closes the reader. A handed-off session
  /// belongs to the helper: closing it here is a [StateError].
  @experimental
  Future<void> closeRead(ReadSession session) async {
    session._requireOwned('closeRead');
    final reader = session._reader;
    if (reader != null) {
      reader.close();
      return;
    }
    if (session._closed) {
      return;
    }
    session._closed = true;
    final result = closeFd(session.fd);
    if (result < 0) {
      throw _errnoException(-result, 'close');
    }
  }

  /// Creates the file [name] directly under the directory [scope] holds and
  /// opens it for writing: a control call that never writes a byte. Write
  /// it with an [FdWriter] in the isolate that produces the bytes (see
  /// [WriteSession]), then commit or abort it.
  ///
  /// Fail-if-exists: a taken name is `already-exists` and nothing is
  /// touched (callers that mean to replace a file delete it first,
  /// deliberately). On iOS the create is exclusive (`O_EXCL`); Android has
  /// no such primitive, so a concurrent create of the same name can slip
  /// past the check there. An abort deletes by name, and only after
  /// checking the file there is still this session's (see
  /// [FdWriter.abort]).
  ///
  /// [mimeType] is the caller's statement, required by Android. Keep the
  /// default for `.writing`/`.part`/marker files: a real type may make a
  /// provider append its own extension, which is then `invalid-name` (the
  /// new file deleted again, as for [createDirectory]).
  ///
  /// [name] follows the leaf-name rule of [lookupChild] ([ArgumentError]).
  /// Other failures: `scope-closed`, `not-a-directory`, `not-found`,
  /// `permission-lost` (on Android also `reason: read-only`).
  ///
  /// Root isolate only. Android and iOS only; throws [UnsupportedError]
  /// elsewhere.
  @experimental
  Future<WriteSession> openWrite({
    required AcquiredScope scope,
    required String name,
    String mimeType = 'application/octet-stream',
  }) async {
    _logger.finest('openWrite()');
    _requireScopePlatform('openWrite');
    _requireLeafName(name);
    _requireScopeLive(scope.id);
    // Before the create, and a little early on purpose: an abort's check
    // accepts a file modified no earlier than this.
    final openedAt = DateTime.now().millisecondsSinceEpoch;
    final result = await _channel.invokeMapMethod<String, Object?>(
      'openWrite',
      {'scope': scope.id, 'name': name, 'mimeType': mimeType},
    );
    if (result == null) {
      throw StateError('Got null response for openWrite');
    }
    return WriteSession._(
      result['fd']! as int,
      result['identifier']! as String,
      scope.id,
      result['fileId'] as String?,
      openedAt,
      canFsync: result['canFsync']! as bool,
    );
  }

  /// Commits a [WriteSession] that no [FdWriter] took over (or, with one,
  /// commits through it): fsync when [fsync] and the session can, close,
  /// and return the file's entry. As [FdWriter.closeWrite].
  @experimental
  Future<ChildEntry> closeWrite(
    WriteSession session, {
    bool fsync = true,
  }) async {
    session._requireOwned('closeWrite');
    final writer = session._writer;
    if (writer != null) {
      return writer.closeWrite(fsync: fsync);
    }
    if (session._closed || session._aborted) {
      throw PlatformException(
        code: 'session-closed',
        message: 'The WriteSession was already closed or aborted',
      );
    }
    final synced = fsync && session.canFsync ? fsyncFd(session.fd) : 0;
    session._closed = true;
    final closed = closeFd(session.fd);
    if (synced < 0) {
      throw _errnoException(-synced, 'fsync');
    }
    if (closed < 0) {
      throw _errnoException(-closed, 'close');
    }
    final entry = await _statEntry(session.identifier);
    try {
      _requireStoredSize(entry, session._bytesWritten, session.canFsync);
    } on PlatformException {
      session._sizeMismatched = true;
      rethrow;
    }
    return entry;
  }

  /// Aborts a [WriteSession]: closes its descriptor and deletes the
  /// partial, only while it is still this session's file (see
  /// [FdWriter.abort]). Idempotent; a partial already gone is success.
  ///
  /// [closeFd] false is the kill path: after a helper holding the
  /// descriptor was killed, its finalizer closed it. This marks the
  /// session aborted and DELETES NOTHING: the root's copy cannot know what
  /// the helper wrote, and without that no check can tell the partial from
  /// a file that took its name since. The partial stays; delete it by name
  /// with [deleteEntry] once no writer can be running (an app's own repair
  /// at its next start, typically). It is allowed only on a handed-off or
  /// already closed session ([StateError] otherwise: the descriptor would
  /// leak).
  @experimental
  Future<void> abortWrite(WriteSession session, {bool closeFd = true}) async {
    if (!closeFd) {
      if (!session._handedOff && !session._closed) {
        throw StateError(
          'abortWrite(closeFd: false) on a session that still owns its '
          'descriptor: it would leak',
        );
      }
      session._aborted = true;
      return;
    }
    session._requireOwned('abortWrite');
    final writer = session._writer;
    if (writer != null) {
      return writer.abort();
    }
    if (session._sizeMismatched) {
      throw StateError(
        'abortWrite() after closeWrite() found bytes this session did not '
        'write; delete the file with deleteEntry if that is meant',
      );
    }
    if (!session._closed) {
      session._closed = true;
      _closeIgnoringResult(session.fd);
    }
    session._aborted = true;
    await _abortPartial(
      session.identifier,
      session._fileId,
      session._bytesWritten,
      session._openedAt,
    );
  }

  static void _closeIgnoringResult(int fd) {
    // An abort gives the file up either way; a failing close must not keep
    // the partial from being deleted.
    final result = closeFd(fd);
    if (result < 0) {
      _logger.warning('abortWrite: close failed with errno ${-result}');
    }
  }

  /// Creates the directory [name] directly under the directory [scope]
  /// holds, and returns its entry. Taking the parent's scope lets a caller
  /// creating many folders pay for one acquire.
  ///
  /// A taken name is loud `already-exists`, never a silent provider
  /// auto-rename (an Android provider that renamed it anyway has its fresh
  /// folder deleted before the throw, so nothing is left behind). A
  /// provider that cleaned the name (FAT-style characters on Android) is
  /// loud `invalid-name` with the provider's name in the details, again
  /// with the residue deleted. Only a fresh, empty folder is ever deleted:
  /// should a provider hand back an existing folder instead, it is kept,
  /// and the details say so (`residue: kept`, its `identifier`).
  /// [ChildEntry.name] is the stored name.
  ///
  /// [name] follows the leaf-name rule of [lookupChild] ([ArgumentError]).
  /// Other failures: `scope-closed`, `not-a-directory`, `not-found`, and
  /// `permission-lost` (on Android also for a read-only grant, `reason:
  /// read-only`).
  ///
  /// Android and iOS only; throws [UnsupportedError] elsewhere.
  @experimental
  Future<ChildEntry> createDirectory({
    required AcquiredScope scope,
    required String name,
  }) async {
    _logger.finest('createDirectory()');
    _requireScopePlatform('createDirectory');
    _requireLeafName(name);
    _requireScopeLive(scope.id);
    final result = await _channel.invokeMapMethod<String, Object?>(
      'createDirectory',
      {'scope': scope.id, 'name': name},
    );
    if (result == null) {
      throw StateError('Got null response for createDirectory');
    }
    return ChildEntry._fromResult(result);
  }

  /// Deletes the file or directory [identifier] names. Single-shot: the
  /// plugin holds access for this call only.
  ///
  /// Idempotent: an entry that is already gone is success, never
  /// `not-found`. "Gone" is proven, never assumed: a provider that does not
  /// answer, or a failing stick, stays loud rather than reading as deleted.
  /// A non-empty directory without [recursive] is loud
  /// `directory-not-empty`; with it, the plugin deletes depth-first
  /// itself rather than trusting a provider's own recursion. Both checks
  /// are best-effort: emptiness is decided by listing, so a child created
  /// concurrently may be deleted anyway. Quiesce writers when that matters.
  ///
  /// A picked folder's own root (the identifier [openDirectory] returned,
  /// or its repaired form) is refused as `root-protected`: only entries
  /// inside a picked folder can be deleted, so one wrong identifier cannot
  /// wipe a whole pick. That includes other spellings of the root on iOS
  /// and on Android's system storage provider; other Android providers are
  /// opaque, and there only the root's own identifier is recognized.
  ///
  /// A recursive delete is not atomic: when it fails partway (a provider
  /// error, or on Android a tree deeper than 256 levels), what it already
  /// deleted stays deleted, and the error is loud. On a failing Android
  /// stick that still lists the parent but cannot read the entry, the entry
  /// reads as gone: the platform reports both as a missing file.
  ///
  /// Other failures: `permission-lost` (on Android also for a read-only
  /// grant, `reason: read-only`).
  ///
  /// Android and iOS only; throws [UnsupportedError] elsewhere.
  @experimental
  Future<void> deleteEntry({
    required String identifier,
    bool recursive = false,
  }) async {
    _logger.finest('deleteEntry()');
    _requireScopePlatform('deleteEntry');
    await _channel.invokeMethod<void>('deleteEntry', {
      'identifier': identifier,
      'recursive': recursive,
    });
  }

  /// Moves [identifier] from the directory [sourceParent] holds into the
  /// one [newParent] holds, renaming it to [newName] when given. A rename
  /// is a move with the same scope twice and a [newName]. Returns a fresh
  /// entry: identifiers may change across a move, so use the returned
  /// [ChildEntry.identifier] from now on.
  ///
  /// [identifier] must be a direct child of [sourceParent] (`not-found`
  /// otherwise). A taken target name is loud `already-exists` and nothing
  /// moves: there is no atomic replace, so a caller that wants one deletes
  /// the target first, deliberately. A provider that cleans [newName] is
  /// `invalid-name` (details: the requested and the provider's name), with
  /// the entry renamed back. A move and a rename together run as two
  /// steps; if the rename fails and moving back fails too, the result is
  /// loud `move-partial`, with the entry's actual identifier in the details
  /// so the caller can find it. A move across providers or storage volumes
  /// is `unsupported-move` and is not attempted (copy, then delete). A
  /// picked folder's own root is `root-protected`, as for [deleteEntry].
  /// A rename that changes only letter case is `already-exists` where the
  /// storage ignores case (shared storage and FAT on Android, APFS on iOS).
  ///
  /// A move or rename can fail after it landed: when the volume goes away
  /// while the result is verified, the error is `permission-lost` (`reason:
  /// volume-absent`), and on Android a move with a rename adds `state:
  /// unknown` and the `candidates` identifiers instead of guessing at a
  /// rollback. List the parent before retrying.
  ///
  /// [newName] follows the leaf-name rule of [lookupChild]
  /// ([ArgumentError]). Other failures: `scope-closed`, `not-a-directory`,
  /// `permission-lost` (on Android also `reason: read-only`).
  ///
  /// Android and iOS only; throws [UnsupportedError] elsewhere.
  @experimental
  Future<ChildEntry> moveEntry({
    required String identifier,
    required AcquiredScope sourceParent,
    required AcquiredScope newParent,
    String? newName,
  }) async {
    _logger.finest('moveEntry()');
    _requireScopePlatform('moveEntry');
    if (newName != null) {
      _requireLeafName(newName);
    }
    _requireScopeLive(sourceParent.id);
    _requireScopeLive(newParent.id);
    final result = await _channel
        .invokeMapMethod<String, Object?>('moveEntry', {
          'identifier': identifier,
          'sourceParent': sourceParent.id,
          'newParent': newParent.id,
          'newName': newName,
        });
    if (result == null) {
      throw StateError('Got null response for moveEntry');
    }
    return ChildEntry._fromResult(result);
  }

  /// `scope-closed` unless [id] is a scope this isolate acquired and has
  /// not released.
  void _requireScopeLive(String id) {
    if (!_liveScopeIds.contains(id)) {
      throw PlatformException(
        code: 'scope-closed',
        message: 'The scope $id was released (or never acquired here)',
      );
    }
  }

  static void _requireLeafName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\u0000')) {
      throw ArgumentError.value(name, 'name', 'Not a single leaf name');
    }
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
