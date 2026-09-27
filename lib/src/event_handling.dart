import 'dart:async';
import 'dart:io';

import 'package:file_picker_writable/src/file_picker_writable.dart';
import 'package:logging/logging.dart';

final _logger = Logger('file_picker_writable.events');

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

/// DropHandlers are registered as callbacks to be called when files are
/// dropped onto the app window. [drop] groups every file of one drag
/// session. Temp files are deleted once the drop is handled, so copy them
/// elsewhere first to keep them.
///
/// The handler must return `true` if it has handled the drop.
///
/// Currently delivered on Android only.
typedef DropHandler = FutureOr<bool> Function(DropEvent drop);

/// DropHoverHandlers are called when a drag hovers over ([entered] is true)
/// or leaves ([entered] is false) the app window. Use it to highlight a
/// drop target. Currently delivered on Android only.
typedef DropHoverHandler = void Function(bool entered);

/// One file of a drop session: [fileInfo] describes the dropped file and
/// [file] is a temporary copy of its contents.
class DropItem {
  DropItem({required this.fileInfo, required this.file});
  final FileInfo fileInfo;
  final File file;
}

/// All files of one drag-and-drop session, delivered as a group.
class DropEvent {
  DropEvent(this.items);
  final List<DropItem> items;
}

abstract class FilePickerEventHandler {
  @Deprecated('Use [handleFileOpen] instead')
  Future<bool> handleFileInfo(FileInfo fileInfo) async => false;
  Future<bool> handleFileOpen(FileInfo fileInfo, File file);
  Future<bool> handleDrop(DropEvent drop);
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
    this.dropHandler,
    this.uriHandler,
    this.errorEventHandler,
  });

  @Deprecated('use [fileOpenHandler]')
  final FileInfoHandler? fileInfoHandler;
  final FileOpenHandler? fileOpenHandler;
  final DropHandler? dropHandler;
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
  Future<bool> handleDrop(DropEvent drop) async =>
      (await dropHandler?.call(drop)) ?? false;

  @override
  Future<bool> handleUri(Uri uri) async => uriHandler?.call(uri) ?? false;

  @override
  Future<bool> handleErrorEvent(ErrorEvent errorEvent) =>
      errorEventHandler?.call(errorEvent) ?? Future.value(false);

  @override
  bool operator ==(Object other) =>
      other is FilePickerEventHandlerLambda &&
      // ignore: deprecated_member_use_from_same_package
      fileInfoHandler == other.fileInfoHandler &&
      fileOpenHandler == other.fileOpenHandler &&
      dropHandler == other.dropHandler &&
      uriHandler == other.uriHandler &&
      errorEventHandler == other.errorEventHandler;

  @override
  int get hashCode => Object.hash(
        // ignore: deprecated_member_use_from_same_package
        fileInfoHandler,
        fileOpenHandler,
        dropHandler,
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

/// A grouped drop delivery: dispatches to
/// [FilePickerEventHandler.handleDrop] and deletes every temp file
/// on dispose.
class FilePickerEventDrop extends FilePickerEvent {
  FilePickerEventDrop(this.event);

  final DropEvent event;

  @override
  String get debugMessage => 'drop';

  @override
  Future<bool> dispatch(FilePickerEventHandler handler) =>
      handler.handleDrop(event);

  @override
  Future<void> dispose() async {
    for (final item in event.items) {
      try {
        await item.file.delete();
      } catch (error) {
        // Best effort: the handler may already have moved or deleted it.
        _logger.fine('Ignoring temp file cleanup failure for ${item.file}.',
            error);
      }
    }
  }
}
