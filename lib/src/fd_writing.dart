part of 'file_picker_writable.dart';

// Gap 3 write sessions, doc/tree-writes-plan.md §4/§5: the write half of
// Gap 2b's reads. Control on the channel (openWrite, and the stat or
// delete that ends a session), bytes over FFI on a detached descriptor
// (FdWriter), one Dart owner per descriptor.

/// How many bytes a writer may write on the root isolate before the debug
/// assertion asks for a helper, as for reads.
const _rootIsolateWriteBudget = 1 << 20;

/// A new file being written, from [FilePickerWritable.openWrite]: a
/// Dart-owned descriptor on a file that exists until it is committed
/// ([FdWriter.closeWrite], [FilePickerWritable.closeWrite]) or aborted
/// ([FdWriter.abort], [FilePickerWritable.abortWrite]), which deletes it.
///
/// Write where the bytes are produced: wrap it with [FdWriter.fromSession]
/// here, or [handoff] it to a helper isolate and wrap the record there
/// with [FdWriter.fromHandoff]. Exactly one of the two, and at most one
/// writer per session. A crash before commit or abort leaves the partial
/// file behind: sweep it by name ([identifier] is its identifier).
///
/// Check [canFsync] where durability matters: a pipe-backed session cannot
/// fsync, and its commit skips the step silently.
@experimental
class WriteSession {
  WriteSession._(
    this.fd,
    this.identifier,
    this._scopeToken,
    this._fileId,
    this._openedAt, {
    required this.canFsync,
  });

  /// The descriptor. A plain int, but it passes to another isolate only
  /// through [handoff].
  final int fd;

  /// The new file's identifier: what an abort deletes and a commit stats.
  final String identifier;

  /// False for a pipe: no fsync on commit, and writes are sequential.
  final bool canFsync;

  final String _scopeToken;

  /// What makes an abort delete only this session's file: the file's
  /// identity where the platform has one (iOS: device and inode).
  final String? _fileId;

  /// When the file was created (ms since the epoch), for the same check
  /// where there is no identity (Android).
  final int _openedAt;

  int _bytesWritten = 0;
  bool _handedOff = false;
  bool _closed = false;
  bool _aborted = false;
  bool _sizeMismatched = false;
  FdWriter? _writer;

  /// Bytes written and acknowledged so far, on the copy that owns the
  /// descriptor: the progress numerator.
  int get bytesWritten => _bytesWritten;

  /// Hands the descriptor to another isolate, as [ReadSession.handoff]:
  /// checks the scope is still acquired (`scope-closed` otherwise), returns
  /// the sendable record and kills this copy for descriptor use. Call it on
  /// the root isolate, before spawning: when it throws, the session is
  /// still yours to [FilePickerWritable.abortWrite].
  ///
  /// After a kill, the helper's finalizer has closed the descriptor: mark
  /// this dead copy aborted with `abortWrite(session, closeFd: false)`,
  /// which deletes nothing (nothing can prove the file under [identifier]
  /// is still this session's); delete the partial by name with
  /// [FilePickerWritable.deleteEntry] once no writer can be running. Never
  /// commit after a kill.
  WriteHandoff handoff() {
    _requireOwned('handoff');
    if (_writer != null) {
      throw StateError(
        'handoff() after an FdWriter was built on this session: hand off '
        'before wrapping, never after',
      );
    }
    final rootToken = RootIsolateToken.instance;
    if (rootToken == null) {
      throw StateError('handoff() runs on the root isolate');
    }
    FilePickerWritable()._requireScopeLive(_scopeToken);
    _handedOff = true;
    return WriteHandoff._(
      fd: fd,
      identifier: identifier,
      canFsync: canFsync,
      scopeToken: _scopeToken,
      rootToken: rootToken,
      fileId: _fileId,
      openedAt: _openedAt,
    );
  }

  void _requireOwned(String verb) {
    if (_handedOff) {
      throw StateError(
        '$verb on a handed-off WriteSession: its owner is the helper now',
      );
    }
  }
}

/// The sendable form of a [WriteSession], made only by
/// [WriteSession.handoff]. Build the helper's writer with
/// [FdWriter.fromHandoff], once. Its fields serve the writer; apps pass
/// the record on and read none of them except [identifier].
@experimental
class WriteHandoff {
  const WriteHandoff._({
    required this.fd,
    required this.identifier,
    required this.canFsync,
    required this.scopeToken,
    required this.rootToken,
    required this.fileId,
    required this.openedAt,
  });

  final int fd;
  final String identifier;
  final bool canFsync;

  /// The [AcquiredScope.id] the session was opened under, checked at
  /// [WriteSession.handoff] and not again in the helper. Not for apps.
  final String scopeToken;

  /// Lets the helper's writer reach the plugin's channel for the stat or
  /// delete that ends the session ([FdWriter.closeWrite],
  /// [FdWriter.abort]). Not for apps.
  final RootIsolateToken rootToken;

  /// The file's identity for the abort check. Not for apps.
  final String? fileId;

  /// When the file was created, for the abort check. Not for apps.
  final int openedAt;
}

/// Writes a session's descriptor with FFI, in the isolate that produces the
/// bytes. Owns the descriptor and one staging buffer of [bufferLength]
/// bytes (Dart heap bytes cannot reach FFI directly, so each chunk is
/// copied there once: memory is bounded by [bufferLength] plus the
/// caller's own chunk); a NativeFinalizer closes the descriptor if the
/// writer is collected or its isolate dies first.
///
/// In a helper, the writer's own [closeWrite] and [abort] call the
/// plugin's channel through the `BackgroundIsolateBinaryMessenger`, set up
/// from the handoff's root token; that keeps an `Isolate.spawn` helper's
/// event loop alive until it exits (`Isolate.run` exits regardless).
///
/// Write on the root isolate only for small files: past 1 MiB per writer,
/// a debug-mode assertion asks for a helper isolate instead.
@experimental
class FdWriter {
  /// Same-isolate path. Checks the scope is acquired now.
  FdWriter.fromSession(WriteSession session, {int bufferLength = 1 << 20})
    : this._(
        session.fd,
        session.identifier,
        session._fileId,
        session._openedAt,
        canFsync: session.canFsync,
        session: session,
        scopeToken: session._scopeToken,
        bufferLength: bufferLength,
      );

  /// Helper-isolate path (also the root's recovery path when the spawn
  /// itself failed, see [ReadSession.handoff]). No scope check: the handoff
  /// made it. A [StateError] when another writer holds the same descriptor.
  FdWriter.fromHandoff(WriteHandoff handoff, {int bufferLength = 1 << 20})
    : this._(
        handoff.fd,
        handoff.identifier,
        handoff.fileId,
        handoff.openedAt,
        canFsync: handoff.canFsync,
        session: null,
        scopeToken: null,
        bufferLength: bufferLength,
        rootToken: handoff.rootToken,
      );

  FdWriter._(
    int fd,
    this.identifier,
    this._fileId,
    this._openedAt, {
    required this.canFsync,
    required WriteSession? session,
    required String? scopeToken,
    required this.bufferLength,
    RootIsolateToken? rootToken,
  }) : _session = session {
    if (bufferLength <= 0) {
      throw ArgumentError.value(
        bufferLength,
        'bufferLength',
        'must be positive',
      );
    }
    if (session != null) {
      session._requireOwned('FdWriter.fromSession');
      if (session._closed) {
        throw StateError('FdWriter.fromSession on a closed WriteSession');
      }
      if (session._writer != null) {
        throw StateError('A WriteSession takes at most one FdWriter');
      }
      FilePickerWritable()._requireScopeLive(scopeToken!);
    }
    if (rootToken != null && RootIsolateToken.instance == null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
    }
    _handle = FdHandle(fd, bufferLength);
    session?._writer = this;
  }

  /// The new file's identifier.
  final String identifier;

  /// False for a pipe: sequential writes, no fsync.
  final bool canFsync;
  final int bufferLength;
  final WriteSession? _session;
  final String? _fileId;
  final int _openedAt;
  late final FdHandle _handle;

  int _total = 0;
  bool _closed = false;
  bool _aborted = false;
  bool _sizeMismatched = false;
  ChildEntry? _committed;
  bool? _lastSyncWasFull;

  /// Whether this writer lives on the root isolate, asked once.
  late final bool _onRootIsolate = RootIsolateToken.instance != null;

  /// Bytes written and acknowledged so far.
  int get bytesWritten => _total;

  /// After a commit with fsync: whether the drive was told to write its
  /// cache through (Apple's `F_FULLFSYNC`) rather than plain fsync. False
  /// where the volume refuses a full flush (exFAT, network volumes) and on
  /// Android, which has none; null before a commit, or without fsync. A
  /// caller that records how durable a copy is reads it here.
  bool? get lastSyncWasFull => _lastSyncWasFull;

  /// Writes all of [bytes] after what was written so far and returns the
  /// new acknowledged total: positional on a file (no shared offset), in
  /// order on a pipe. Chunks longer than [bufferLength] are staged and
  /// written in parts; there is no size cap. A full non-blocking pipe is
  /// waited on.
  ///
  /// A volume that accepts no more bytes without failing (a write that
  /// returns 0) is loud as `errno-28` (ENOSPC) with `synthesized: true` in
  /// the details, never a silent short write; that a full volume answers
  /// this way is the assumption, unmeasured. Errors keep [bytesWritten]
  /// exact: bytes that landed before an error are counted. Otherwise as
  /// for [FdReader.readChunk]: `permission-lost` (EIO, ENXIO, ENODEV; the
  /// writer closes its descriptor at once, and the partial is left for
  /// [abort] or the orphan sweep), `session-closed`, `errno-<n>`.
  int writeChunk(Uint8List bytes) {
    if (_closed) {
      throw PlatformException(
        code: 'session-closed',
        message: 'FdWriter is closed',
      );
    }
    var offset = 0;
    while (offset < bytes.length) {
      final remaining = bytes.length - offset;
      final length = remaining < bufferLength ? remaining : bufferLength;
      _handle.buffer.setRange(0, length, bytes, offset);
      var done = 0;
      while (done < length) {
        final written = _check(
          canFsync
              ? _handle.pwrite(_total, length - done, from: done)
              : _handle.write(length - done, from: done),
        );
        if (written == 0) {
          throw PlatformException(
            code: 'errno-28',
            message:
                'The volume accepted no more bytes after $_total: treated as full',
            details: <String, Object?>{
              'domain': 'errno',
              'code': 28,
              'synthesized': true,
            },
          );
        }
        done += written;
        _total += written;
        _session?._bytesWritten = _total;
      }
      offset += length;
    }
    assert(_withinRootBudget());
    return _total;
  }

  bool _withinRootBudget() {
    if (_total > _rootIsolateWriteBudget && _onRootIsolate) {
      throw AssertionError(
        'FdWriter wrote more than 1 MiB on the root isolate, which costs '
        'frames: hand the session off to a helper isolate '
        '(WriteSession.handoff) and write there',
      );
    }
    return true;
  }

  int _check(int count) {
    if (count >= 0) {
      return count;
    }
    final error = _errnoException(-count, 'write');
    if (error.code == 'permission-lost') {
      _release();
    }
    throw error;
  }

  /// Commits the file: fsyncs it (when [fsync] and [canFsync]; on Apple a
  /// full flush through the drive's cache where the volume supports it),
  /// closes the descriptor, and returns the file's entry as stored.
  /// Idempotent: a second call returns the same entry. `fsync` defaults
  /// to true; pass false only where something else (verify-after-copy) is
  /// the guarantee.
  ///
  /// An fsync or close that fails still releases the descriptor, then
  /// throws: the file stays as the partial it is, for [abort]. A stored
  /// size that differs from [bytesWritten] (someone else wrote to the file
  /// meanwhile) is loud `size-mismatch`, the file left alone; a pipe-backed
  /// session cannot make this check. A scope released meanwhile does not
  /// fail a commit: the bytes are down. After [abort] this is
  /// `session-closed`.
  ///
  /// On Android, the system's media scan ran when the file was created,
  /// empty: a finished media file may not show in gallery apps until it is
  /// scanned again.
  Future<ChildEntry> closeWrite({bool fsync = true}) async {
    final committed = _committed;
    if (committed != null) {
      return committed;
    }
    if (_aborted || _closed) {
      throw PlatformException(
        code: 'session-closed',
        message: 'FdWriter was aborted or lost its descriptor',
      );
    }
    final synced = fsync && canFsync ? _handle.fsync() : 0;
    final closed = _release();
    if (synced < 0) {
      throw _errnoException(-synced, 'fsync');
    }
    _lastSyncWasFull = fsync && canFsync ? synced == 1 : null;
    if (closed < 0) {
      throw _errnoException(-closed, 'close');
    }
    final entry = await _statEntry(identifier);
    try {
      _requireStoredSize(entry, _total, canFsync);
    } on PlatformException {
      _sizeMismatched = true;
      _session?._sizeMismatched = true;
      rethrow;
    }
    _committed = entry;
    return entry;
  }

  /// Gives the file up: closes the descriptor and deletes the partial.
  /// Idempotent; a partial that is already gone is success.
  ///
  /// The delete is by name, so it checks first that the file there is
  /// still this session's, by identity: the file recorded at create (iOS:
  /// device and birth time, plus the inode where the volume keeps it
  /// stable; Android: the inode), holding [bytesWritten] bytes. Anything
  /// else (the user renamed it away and another file took the name) is
  /// `not-found` with `reason: replaced`; a session whose file has no
  /// identity (a pipe) is `reason: unverifiable`; nothing is deleted either
  /// way, and the details say `residue: kept`. A committed file is not
  /// aborted, nor one whose commit found a `size-mismatch` (someone else's
  /// bytes are in it) ([StateError]): delete it with
  /// [FilePickerWritable.deleteEntry] when that is meant.
  Future<void> abort() async {
    if (_committed != null || _sizeMismatched) {
      throw StateError(
        'abort() after closeWrite(): the file is committed, or holds bytes '
        'this session did not write; delete it with deleteEntry if that is '
        'meant',
      );
    }
    if (!_closed) {
      _release();
    }
    _aborted = true;
    _session?._aborted = true;
    await _abortPartial(identifier, _fileId, _total, _openedAt);
  }

  int _release() {
    _closed = true;
    _session?._closed = true;
    return _handle.close();
  }
}

/// `size-mismatch` unless a committed file holds exactly the bytes its
/// session wrote (pipes cannot tell).
void _requireStoredSize(ChildEntry entry, int written, bool canFsync) {
  final size = entry.size;
  if (canFsync && size != null && size != written) {
    throw PlatformException(
      code: 'size-mismatch',
      message:
          'The file holds $size bytes, but this session wrote $written: '
          'something else wrote to it',
      details: <String, Object?>{'size': size, 'written': written},
    );
  }
}

/// The entry of a just-committed file, from either isolate.
Future<ChildEntry> _statEntry(String identifier) async {
  final result = await FilePickerWritable._channel
      .invokeMapMethod<String, Object?>('statEntry', {
        'identifier': identifier,
      });
  if (result == null) {
    throw PlatformException(
      code: 'not-found',
      message: 'The committed file $identifier is gone',
    );
  }
  return ChildEntry._fromResult(result);
}

/// Deletes an aborted partial, from either isolate, only while it is still
/// the session's own file; gone is success.
Future<void> _abortPartial(
  String identifier,
  String? fileId,
  int bytesWritten,
  int openedAt,
) => FilePickerWritable._channel.invokeMethod<void>('abortPartial', {
  'identifier': identifier,
  'fileId': fileId,
  'bytesWritten': bytesWritten,
  'openedAt': openedAt,
});
