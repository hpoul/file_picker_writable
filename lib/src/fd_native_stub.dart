// The fd byte path where dart:ffi does not exist (the web): the same API
// as fd_native.dart, unsupported. openRead throws UnsupportedError there
// before anything reaches it.

import 'dart:typed_data';

/// See fd_native.dart.
final class FdHandle {
  FdHandle(this.fd, int bufferLength) {
    throw UnsupportedError('File descriptor reads need dart:ffi');
  }

  final int fd;

  Uint8List get buffer => throw UnsupportedError('No dart:ffi');

  int pread(int position, int length) => throw UnsupportedError('No dart:ffi');

  int read(int length) => throw UnsupportedError('No dart:ffi');

  int close() => throw UnsupportedError('No dart:ffi');
}

/// See fd_native.dart.
int closeFd(int fd) => throw UnsupportedError('No dart:ffi');
