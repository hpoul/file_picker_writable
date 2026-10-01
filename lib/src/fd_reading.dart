part of 'file_picker_writable.dart';

// Gap 2b, doc/large-file-reads-plan.md: control on the channel (openRead),
// bytes over FFI on a detached file descriptor (FdReader), one Dart owner
// per descriptor. The FFI half lives in fd_native.dart, imported only where
// dart:ffi exists.

/// How many bytes a reader may read on the root isolate before the debug
/// assertion asks for a helper (doc/large-file-reads-plan.md §3a).
const _rootIsolateReadBudget = 1 << 20;

/// An open, Dart-owned file descriptor from [FilePickerWritable.openRead].
///
/// Read it in the isolate that consumes the bytes: wrap it with
/// [FdReader.fromSession] here, or [handoff] it to a helper isolate and
/// wrap the record there with [FdReader.fromHandoff]. Exactly one of the
/// two, and at most one reader per session. A session that is never
/// wrapped is closed with [FilePickerWritable.closeRead]: a session has no
/// finalizer, so one that is dropped unwrapped leaks its descriptor.
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
  /// Call it before spawning, not inside the spawn expression: when it
  /// throws, the session is still yours, and only [FilePickerWritable.closeRead]
  /// releases it.
  ///
  /// Throws [StateError] once a reader was built on this session (bytes
  /// already flow here: hand off before wrapping, never after).
  ///
  /// Recovery: only when the spawn itself fails (`Isolate.spawn` or
  /// `Isolate.run` throws an `IsolateSpawnException`) has nobody taken the
  /// record, and only then may this isolate build [FdReader.fromHandoff] on
  /// it and close it. After any other failure, a helper may already have
  /// built its reader and closed the descriptor (a killed helper's
  /// finalizer closes it too), and adopting the record again would read or
  /// close a number the process has since reused: leave it. A helper killed
  /// before it built its reader leaks the descriptor; that is the accepted
  /// cost of never double-closing.
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
    return ReadHandoff._(
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

/// The sendable form of a [ReadSession], made only by
/// [ReadSession.handoff]: plain values, so it crosses isolates as is.
/// Build the helper's reader with [FdReader.fromHandoff], once: a second
/// reader on the same record, while the first is open, is a [StateError].
@experimental
class ReadHandoff {
  const ReadHandoff._({
    required this.fd,
    required this.seekable,
    required this.length,
    required this.scopeToken,
  });

  final int fd;
  final bool seekable;
  final int? length;

  /// The [AcquiredScope.id] the session was opened under, for provenance.
  /// Checked at [ReadSession.handoff]; the helper does not check it again.
  /// Keep the scope acquired until the helper closes: releasing it early
  /// does not break the open descriptor (neither platform re-checks access
  /// on one), but it ends the plugin's own guarantees, e.g. on iOS the
  /// security scope behind any other access to the same files.
  final String scopeToken;
}

/// Reads a session's descriptor with FFI, in the isolate that consumes the
/// bytes. Owns the descriptor and one read buffer of [bufferLength] bytes;
/// [close] releases the descriptor, and a NativeFinalizer releases it if the
/// reader is collected or its isolate dies first.
///
/// Read on the root isolate only for small one-shot reads: past 1 MiB per
/// reader, a debug-mode assertion asks for a helper isolate instead (see
/// [ReadSession.handoff]).
@experimental
class FdReader {
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
  /// spawn, see [ReadSession.handoff]). No scope check here: the handoff
  /// made it. A [StateError] when another reader holds the same descriptor
  /// (the record was consumed twice).
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
    _handle = FdHandle(fd, bufferLength);
    session?._reader = this;
  }

  final bool seekable;
  final int bufferLength;
  final ReadSession? _session;
  final String? _scopeToken;
  late final FdHandle _handle;
  bool _closed = false;

  /// Where the next sequential read starts (pipes only).
  int _position = 0;

  /// Bytes read so far, for the root-isolate budget (debug mode only).
  int _bytesRead = 0;

  /// Whether this reader lives on the root isolate, asked once.
  late final bool _onRootIsolate = RootIsolateToken.instance != null;

  /// Reads up to [length] bytes at [position] and returns a VIEW of the
  /// read buffer, valid until the next call: consume it in place, copy it
  /// to keep it. (A view kept longer stays memory-safe, since it keeps the
  /// buffer alive, but shows whatever a later read put there.) An empty
  /// view is end of file. Short reads are looped to [length] or end of
  /// file.
  ///
  /// [position] and [length] must not be negative, and [length] must not
  /// exceed [bufferLength] ([ArgumentError]). On a pipe ([seekable] false)
  /// positions only move forward: a later one skips by reading, an earlier
  /// one is `seek-unsupported`.
  ///
  /// Errors are [PlatformException]s: `permission-lost` for EIO, ENXIO or
  /// ENODEV, `session-closed` after [close] or for EBADF,
  /// `seek-unsupported`, and any other errno loud as `errno-<n>`, where n
  /// is the platform's own number (ENOTCONN is 107 on Linux and Android,
  /// 57 on Darwin).
  ///
  /// `permission-lost` is final: the media is gone, and the reader closes
  /// itself at once (a pulled volume may get the processes still holding
  /// descriptors on it killed), so every later call is `session-closed`,
  /// never an empty view that would read as a complete file. Other readers
  /// on the same volume keep their descriptors until their own next read.
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
    final Uint8List view;
    if (seekable) {
      view = _result(_handle.pread(position, length));
    } else {
      view = _readSequential(position, length);
    }
    assert(_withinRootBudget(view.length));
    return view;
  }

  Uint8List _readSequential(int position, int length) {
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
      final skipped = _check(_handle.read(skip));
      if (skipped == 0) {
        return Uint8List.sublistView(_handle.buffer, 0, 0);
      }
      _position += skipped;
    }
    final read = _result(_handle.read(length));
    _position += read.length;
    return read;
  }

  bool _withinRootBudget(int count) {
    _bytesRead += count;
    if (_bytesRead > _rootIsolateReadBudget && _onRootIsolate) {
      throw AssertionError(
        'FdReader read more than 1 MiB on the root isolate, which costs '
        'frames: hand the session off to a helper isolate '
        '(ReadSession.handoff) and read there',
      );
    }
    return true;
  }

  Uint8List _result(int count) =>
      Uint8List.sublistView(_handle.buffer, 0, _check(count));

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

  /// Closes the descriptor. Idempotent. Built from a session, it also
  /// checks the scope is still acquired, and throws `scope-closed` after
  /// the cleanup if it was released mid-read.
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
    _session?._closed = true;
    return _handle.close();
  }
}

/// The taxonomy for a failed descriptor call. n in `errno-<n>` is the
/// platform's own errno number, not a portable code.
PlatformException _errnoException(int errno, String operation) {
  final kind = switch (errno) {
    // EIO, ENXIO, ENODEV after the descriptor was detached: the media is
    // gone. A revoked grant does not fail an open descriptor. (The same
    // numbers on Linux, Android and Darwin.)
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
