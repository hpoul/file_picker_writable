import 'dart:async';
import 'dart:io';

import 'package:file_picker_writable/src/file_picker_writable.dart';
import 'package:quiver/core.dart';

@Deprecated('Use [FileOpenHandler] instead.')
typedef FileInfoHandler = FutureOr<bool> Function(FileInfo fileInfo);

/// FileOpenHandlers are registered as callbacks to be called when
/// the app is launched for a file selection.
/// [file] (and [fileInfo].file will be deleted after this function completes.)
///
/// The handler must return `true` if it has handled the file.
typedef FileOpenHandler = FutureOr<bool> Function(FileInfo fileInfo, File file);
typedef UriHandler = bool Function(Uri uri);
typedef ErrorEventHandler = Future<bool> Function(ErrorEvent errorEvent);

abstract class FilePickerEventHandler {
  @Deprecated('Use [handleFileOpen] instead')
  Future<bool> handleFileInfo(FileInfo fileInfo) async => false;
  Future<bool> handleFileOpen(FileInfo fileInfo, File file);
  Future<bool> handleUri(Uri uri);
  Future<bool> handleErrorEvent(ErrorEvent errorEvent) async => false;
}

class ErrorEvent {
  ErrorEvent({required this.message});
  factory ErrorEvent.fromJson(Map<dynamic, dynamic> map) =>
      ErrorEvent(message: map['message'] as String? ?? 'Invalid error event');

  final String message;

  @override
  String toString() {
    return 'ErrorEvent{message: $message}';
  }
}

class FilePickerEventHandlerLambda extends FilePickerEventHandler {
  FilePickerEventHandlerLambda({
    this.fileInfoHandler,
    this.fileOpenHandler,
    this.uriHandler,
    this.errorEventHandler,
  });

  @Deprecated('use [fileOpenHandler]')
  final FileInfoHandler? fileInfoHandler;
  final FileOpenHandler? fileOpenHandler;
  final UriHandler? uriHandler;
  final ErrorEventHandler? errorEventHandler;

  @Deprecated('replaced by [handleFileOpen]')
  @override
  Future<bool> handleFileInfo(FileInfo fileInfo) async =>
      (await fileInfoHandler?.call(fileInfo)) ?? false;

  @override
  Future<bool> handleFileOpen(FileInfo fileInfo, File file) async =>
      (await fileOpenHandler?.call(fileInfo, file)) ?? false;

  @override
  Future<bool> handleUri(Uri uri) async => uriHandler?.call(uri) ?? false;

  @override
  Future<bool> handleErrorEvent(ErrorEvent errorEvent) =>
      errorEventHandler?.call(errorEvent) ?? Future.value(false);

  @override
  bool operator ==(dynamic other) =>
      other is FilePickerEventHandlerLambda &&
      // ignore: deprecated_member_use_from_same_package
      fileInfoHandler == other.fileInfoHandler &&
      fileOpenHandler == other.fileOpenHandler &&
      uriHandler == other.uriHandler &&
      errorEventHandler == other.errorEventHandler;

  @override
  int get hashCode => hash4(
        // ignore: deprecated_member_use_from_same_package
        fileInfoHandler,
        fileOpenHandler,
        uriHandler,
        errorEventHandler,
      );
}

abstract class FilePickerEvent {
  FilePickerEvent();
  Future<bool> dispatch(FilePickerEventHandler handler);
  Future<void>? dispose();
  String get debugMessage;
}

class FilePickerEventLambda extends FilePickerEvent {
  FilePickerEventLambda(this.dispatchLambda, this.disposeLambda,
      {required this.debugMessage});
  final Future<bool> Function(FilePickerEventHandler handler) dispatchLambda;
  final Future<void>? Function() disposeLambda;
  @override
  final String debugMessage;

  @override
  Future<bool> dispatch(FilePickerEventHandler handler) =>
      dispatchLambda(handler);

  @override
  Future<void>? dispose() => disposeLambda();
}

class FilePickerEventOpen extends FilePickerEvent {
  FilePickerEventOpen(this._fileInfo, this._file);

  final FileInfo _fileInfo;
  final File _file;

  bool noCleanupDeprecatedFileInfo = false;

  @override
  String get debugMessage => 'fileOpen';

  @override
  Future<bool> dispatch(FilePickerEventHandler handler) async {
    if (await handler.handleFileOpen(_fileInfo, _file)) {
      return true;
    }
    // as a fallback invoke deprecated `handleFileInfo`.
    // ignore: deprecated_member_use_from_same_package
    if (await handler.handleFileInfo(_fileInfo)) {
      noCleanupDeprecatedFileInfo = true;
      return true;
    }
    return false;
  }

  @override
  Future<void> dispose() async {
    if (!noCleanupDeprecatedFileInfo) {
      await _file.delete();
    }
  }
}
