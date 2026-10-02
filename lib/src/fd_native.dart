// Bindings to the fd shim (src/fpw_fd.c), built as a code asset by
// hook/build.dart. Non-leaf on purpose: a cold-storage read can block,
// which a leaf call must not (doc/large-file-reads-plan.md §5).
//
// Imported only where dart:ffi exists (fd_native_stub.dart elsewhere), so
// web builds never see dart:ffi.

// The names are the C symbols, as @Native resolves them.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:typed_data';

/// The shim's owner record of one adopted descriptor.
final class FpwOwner extends Opaque {}

@Native<Pointer<Uint8> Function(Int64)>()
external Pointer<Uint8> fpw_buffer_new(int length);

@Native<Void Function(Pointer<Void>)>()
external void fpw_buffer_free(Pointer<Void> buffer);

@Native<Pointer<FpwOwner> Function()>()
external Pointer<FpwOwner> fpw_owner_new();

@Native<Int32 Function(Pointer<FpwOwner>, Int32)>()
external int fpw_adopt(Pointer<FpwOwner> owner, int fd);

@Native<Int64 Function(Int32, Pointer<Uint8>, Int64, Int64)>()
external int fpw_pread_full(
  int fd,
  Pointer<Uint8> buffer,
  int offset,
  int length,
);

@Native<Int64 Function(Int32, Pointer<Uint8>, Int64)>()
external int fpw_read_full(int fd, Pointer<Uint8> buffer, int length);

@Native<Int64 Function(Int32, Pointer<Uint8>, Int64, Int64)>()
external int fpw_pwrite_full(
  int fd,
  Pointer<Uint8> buffer,
  int offset,
  int length,
);

@Native<Int64 Function(Int32, Pointer<Uint8>, Int64)>()
external int fpw_write_full(int fd, Pointer<Uint8> buffer, int length);

@Native<Int32 Function(Int32)>()
external int fpw_fsync(int fd);

@Native<Int32 Function(Int32)>()
external int fpw_close(int fd);

@Native<Int32 Function(Pointer<FpwOwner>)>()
external int fpw_release(Pointer<FpwOwner> owner);

@Native<Void Function(Pointer<Void>)>()
external void fpw_release_finalize(Pointer<Void> owner);

/// One adopted descriptor and its buffer: what an FdReader or FdWriter
/// holds.
///
/// The descriptor is released by [close] or, if this is collected or its
/// isolate dies first, by a NativeFinalizer. The buffer belongs to Dart:
/// [buffer] and every view of it keep it alive, so no view can outlive it.
final class FdHandle implements Finalizable {
  /// Adopts [fd] with a fresh [bufferLength]-byte buffer. A [StateError]
  /// when another handle owns [fd] already (a handoff record consumed
  /// twice) or memory runs out; [fd] is then not adopted.
  FdHandle(this.fd, int bufferLength) {
    // The buffer first: a failed adopt then leaves only memory behind,
    // which the buffer's own finalizer frees.
    final pointer = fpw_buffer_new(bufferLength);
    if (pointer == nullptr) {
      throw StateError('Out of memory for a $bufferLength-byte read buffer');
    }
    _buffer = pointer;
    buffer = pointer.asTypedList(
      bufferLength,
      finalizer: _bufferFree,
      token: pointer.cast(),
    );
    final owner = fpw_owner_new();
    if (owner == nullptr) {
      throw StateError('Out of memory adopting descriptor $fd');
    }
    // On failure the shim frees the record; fd stays unadopted.
    final result = fpw_adopt(owner, fd);
    if (result == -16 /* EBUSY */ ) {
      throw StateError(
        'Descriptor $fd is already owned by a reader or writer: either a '
        'handoff record was consumed twice, or the descriptor was closed '
        "behind a live reader's or writer's back and its number reused",
      );
    }
    if (result < 0) {
      throw StateError('Out of memory adopting descriptor $fd');
    }
    _owner = owner;
    _finalizer.attach(this, _owner.cast(), detach: this);
  }

  static final _bufferFree =
      Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
        fpw_buffer_free,
      ).cast<NativeFinalizerFunction>();

  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      fpw_release_finalize,
    ).cast(),
  );

  final int fd;
  late final Pointer<Uint8> _buffer;
  late final Pointer<FpwOwner> _owner;

  /// The read buffer (a writer's staging buffer), owned by Dart.
  late final Uint8List buffer;

  /// Positional read into [buffer]: the count, or -errno.
  int pread(int position, int length) =>
      fpw_pread_full(fd, _buffer, position, length);

  /// Sequential read into [buffer]: the count, or -errno.
  int read(int length) => fpw_read_full(fd, _buffer, length);

  /// Positional write of [length] bytes of [buffer], starting at [from]:
  /// the count (short when the volume wrote 0, or when an error followed
  /// some bytes), or -errno when nothing was written.
  int pwrite(int position, int length, {int from = 0}) =>
      fpw_pwrite_full(fd, _buffer + from, position, length);

  /// Sequential write of [buffer]'s bytes, as [pwrite].
  int write(int length, {int from = 0}) =>
      fpw_write_full(fd, _buffer + from, length);

  /// Makes the bytes durable: 1 for a full flush through the drive's cache
  /// (Apple's F_FULLFSYNC), 0 for plain fsync, or -errno.
  int fsync() => fpw_fsync(fd);

  /// Releases the descriptor: 0, or -errno from close. Call at most once.
  int close() {
    _finalizer.detach(this);
    return fpw_release(_owner);
  }
}

/// Closes a bare descriptor: 0, or -errno.
int closeFd(int fd) => fpw_close(fd);

/// fsyncs a bare descriptor: 0, or -errno.
int fsyncFd(int fd) => fpw_fsync(fd);
