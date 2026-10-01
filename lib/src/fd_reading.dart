part of 'file_picker_writable.dart';

// Gap 2b, doc/large-file-reads-plan.md: control on the channel (openRead),
// bytes over FFI on a detached file descriptor (FdReader), one Dart owner
// per descriptor.

/// An open, Dart-owned file descriptor from [FilePickerWritable.openRead].
///
/// Read it in the isolate that consumes the bytes: wrap it with
/// [FdReader.fromSession] here, or [handoff] it to a helper isolate and
/// wrap the record there with [FdReader.fromHandoff]. Exactly one of the
/// two, and at most one reader per session. A session that is never
/// wrapped is closed with [FilePickerWritable.closeRead].
@experimental
class ReadSession {
  ReadSession._(
    this.fd,
    this._scopeToken, {
    required this.seekable,
    required this.length,
  });

  /// The descriptor. A plain int: it passes to another isolate for free,
  /// but only through [handoff], never by itself.
  final int fd;

  /// False for a pipe: sequential reads only, forward-only positions.
  final bool seekable;

  /// The file's length, or null for a pipe.
  final int? length;

  final String _scopeToken;

  bool _handedOff = false;
  bool _closed = false;
  FdReader? _reader;

  /// Hands the descriptor to another isolate. Checks the scope is still
  /// acquired (`scope-closed` otherwise; the helper side does not check
  /// again), returns the sendable record, and kills this copy: any later fd
  /// use of this session is a [StateError]. Send the record, not [fd].
  ///
  /// Throws [StateError] once a reader was built on this session (bytes
  /// already flow here: hand off before wrapping, never after).
  ///
  /// If the helper cannot take it (the spawn throws, or the helper dies
  /// before building its reader), recover by building
  /// [FdReader.fromHandoff] on this same record here and closing it. A
  /// kill before the helper's reader exists leaks the descriptor.
  ReadHandoff handoff() {
    _requireOwned('handoff');
    if (_reader != null) {
      throw StateError(
        'handoff() after an FdReader was built on this session: hand off '
        'before wrapping, never after',
      );
    }
    FilePickerWritable()._requireScopeLive(_scopeToken);
    _handedOff = true;
    return ReadHandoff(
      fd: fd,
      seekable: seekable,
      length: length,
      scopeToken: _scopeToken,
    );
  }

  void _requireOwned(String verb) {
    if (_handedOff) {
      throw StateError(
        '$verb on a handed-off ReadSession: its owner is the helper now',
      );
    }
  }
}

/// The sendable form of a [ReadSession]: plain values, so it crosses
/// isolates as is. Build the helper's reader with [FdReader.fromHandoff].
@experimental
class ReadHandoff {
  const ReadHandoff({
    required this.fd,
    required this.seekable,
    required this.length,
    required this.scopeToken,
  });

  final int fd;
  final bool seekable;
  final int? length;

  /// The [AcquiredScope.id] the session was opened under, for provenance.
  /// Checked at [ReadSession.handoff]; the helper does not check it again,
  /// so the scope MUST stay acquired until the helper closes.
  final String scopeToken;
}

/// Reads a session's descriptor with FFI, in the isolate that consumes the
/// bytes. Owns the descriptor and one native buffer of [bufferLength]
/// bytes; [close] releases both, and a NativeFinalizer releases them if the
/// reader is collected or its isolate dies first.
@experimental
class FdReader implements Finalizable {
  /// Same-isolate path. Checks the scope is acquired now and at [close].
  FdReader.fromSession(ReadSession session, {int bufferLength = 1 << 20})
    : this._(
        session.fd,
        seekable: session.seekable,
        session: session,
        scopeToken: session._scopeToken,
        bufferLength: bufferLength,
      );

  /// Helper-isolate path (also the root's recovery path after a failed
  /// hand-off). No scope check here: [ReadSession.handoff] made it.
  FdReader.fromHandoff(ReadHandoff handoff, {int bufferLength = 1 << 20})
    : this._(
        handoff.fd,
        seekable: handoff.seekable,
        session: null,
        scopeToken: null,
        bufferLength: bufferLength,
      );

  FdReader._(
    int fd, {
    required this.seekable,
    required ReadSession? session,
    required String? scopeToken,
    required this.bufferLength,
  }) : _session = session,
       _scopeToken = scopeToken {
    if (bufferLength <= 0) {
      throw ArgumentError.value(
        bufferLength,
        'bufferLength',
        'must be positive',
      );
    }
    if (session != null) {
      session._requireOwned('FdReader.fromSession');
      if (session._closed) {
        throw StateError('FdReader.fromSession on a closed ReadSession');
      }
      if (session._reader != null) {
        throw StateError('A ReadSession takes at most one FdReader');
      }
      FilePickerWritable()._requireScopeLive(scopeToken!);
    }
    final record = fpw_reader_new(fd, bufferLength);
    if (record == nullptr) {
      throw StateError('Out of memory for a $bufferLength-byte read buffer');
    }
    _record = record;
    _view = fpw_reader_buffer(record).asTypedList(bufferLength);
    _finalizer.attach(
      this,
      record.cast(),
      detach: this,
      externalSize: bufferLength,
    );
    session?._reader = this;
  }

  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      fpw_reader_finalize,
    ).cast(),
  );

  final bool seekable;
  final int bufferLength;
  final ReadSession? _session;
  final String? _scopeToken;
  late final Pointer<FpwReader> _record;
  late final Uint8List _view;
  bool _closed = false;

  /// Where the next sequential read starts (pipes only).
  int _position = 0;

  /// Reads up to [length] bytes at [position] and returns a VIEW of the
  /// native buffer, valid until the next call or [close]: consume it in
  /// place, copy it to keep it. An empty view is end of file. Short reads
  /// are looped to [length] or end of file.
  ///
  /// [position] and [length] must not be negative, and [length] must not
  /// exceed [bufferLength] ([ArgumentError]). On a pipe ([seekable] false)
  /// positions only move forward: a later one skips by reading, an earlier
  /// one is `seek-unsupported`.
  ///
  /// Errors are [PlatformException]s: `permission-lost` for EIO, ENXIO or
  /// ENODEV (media detached; the reader closes itself at once, since a
  /// pulled volume may get processes holding descriptors on it killed),
  /// `session-closed` after [close] or for EBADF, `seek-unsupported`, and
  /// any other errno loud as `errno-<n>`.
  Uint8List readChunk(int position, int length) {
    if (_closed) {
      throw PlatformException(
        code: 'session-closed',
        message: 'FdReader is closed',
      );
    }
    if (position < 0) {
      throw ArgumentError.value(position, 'position', 'must not be negative');
    }
    if (length < 0 || length > bufferLength) {
      throw ArgumentError.value(length, 'length', 'must be 0..$bufferLength');
    }
    if (seekable) {
      return _result(fpw_pread_full(_record, position, length));
    }
    if (position < _position) {
      throw PlatformException(
        code: 'seek-unsupported',
        message:
            'A pipe only reads forward: position $position is before $_position',
      );
    }
    while (_position < position) {
      final skip = position - _position < bufferLength
          ? position - _position
          : bufferLength;
      final skipped = _check(fpw_read_full(_record, skip));
      if (skipped == 0) {
        return Uint8List.sublistView(_view, 0, 0);
      }
      _position += skipped;
    }
    final read = _result(fpw_read_full(_record, length));
    _position += read.length;
    return read;
  }

  Uint8List _result(int count) =>
      Uint8List.sublistView(_view, 0, _check(count));

  int _check(int count) {
    if (count >= 0) {
      return count;
    }
    final errno = -count;
    final error = _errnoException(errno, 'read');
    if (error.code == 'permission-lost') {
      _release();
    }
    throw error;
  }

  /// Closes the descriptor and frees the buffer. Idempotent. Built from a
  /// session, it also checks the scope is still acquired, and throws
  /// `scope-closed` after the cleanup if it was released mid-read.
  void close() {
    if (_closed) {
      return;
    }
    final result = _release();
    final token = _scopeToken;
    if (token != null) {
      FilePickerWritable()._requireScopeLive(token);
    }
    if (result < 0) {
      throw _errnoException(-result, 'close');
    }
  }

  int _release() {
    _closed = true;
    _finalizer.detach(this);
    _session?._closed = true;
    return fpw_reader_close(_record);
  }
}

PlatformException _errnoException(int errno, String operation) {
  final kind = switch (errno) {
    // EIO, ENXIO, ENODEV after the descriptor was detached: the media is
    // gone. A revoked grant does not fail an open descriptor.
    5 || 6 || 19 => 'permission-lost',
    // EBADF: closed already, a bug on the caller's side, never a live fd.
    9 => 'session-closed',
    _ => 'errno-$errno',
  };
  return PlatformException(
    code: kind,
    message: '$operation failed with errno $errno',
    details: <String, Object?>{'domain': 'errno', 'code': errno},
  );
}
