// Copyright (c) 2019 Herbert Poul. MIT License, see LICENSE.
//
// The byte path of doc/large-file-reads-plan.md §5: the few syscalls Dart
// makes on a detached file descriptor, wrapped so each returns -errno from
// the call itself (an errno read through a second FFI call can be stale:
// the VM may make syscalls of its own in between) and retries EINTR
// inside. Plus one cleanup record {fd, buffer} that explicit close and the
// NativeFinalizer backstop release the same way, so the GC/kill path never
// leaks the buffer.

// One pread signature on every platform: 64-bit offsets on 32-bit Android
// too (pread64 there), plain pread on Darwin and 64-bit Linux.
#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#if defined(_WIN32)
#define FPW_EXPORT __declspec(dllexport)
#else
#define FPW_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

typedef struct {
  int32_t fd;
  uint8_t* buffer;
} fpw_reader;

// A cleanup record owning `fd` and a fresh buffer of `buffer_length`
// bytes, or NULL when out of memory (the fd is then still the caller's).
FPW_EXPORT fpw_reader* fpw_reader_new(int32_t fd, int64_t buffer_length) {
  fpw_reader* reader = malloc(sizeof(fpw_reader));
  if (reader == NULL) {
    return NULL;
  }
  reader->buffer = malloc(buffer_length > 0 ? (size_t)buffer_length : 1);
  if (reader->buffer == NULL) {
    free(reader);
    return NULL;
  }
  reader->fd = fd;
  return reader;
}

FPW_EXPORT uint8_t* fpw_reader_buffer(fpw_reader* reader) {
  return reader->buffer;
}

// Reads up to `length` bytes at `offset` into the record's buffer, looping
// over short reads until `length` or end of file. Returns the byte count
// (0 at end of file) or -errno.
FPW_EXPORT int64_t fpw_pread_full(fpw_reader* reader, int64_t offset, int64_t length) {
  int64_t total = 0;
  while (total < length) {
    ssize_t n = pread(reader->fd, reader->buffer + total, (size_t)(length - total),
                      (off_t)(offset + total));
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -(int64_t)errno;
    }
    if (n == 0) {
      break;
    }
    total += n;
  }
  return total;
}

// The same for a non-seekable descriptor (a pipe): sequential read.
FPW_EXPORT int64_t fpw_read_full(fpw_reader* reader, int64_t length) {
  int64_t total = 0;
  while (total < length) {
    ssize_t n = read(reader->fd, reader->buffer + total, (size_t)(length - total));
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -(int64_t)errno;
    }
    if (n == 0) {
      break;
    }
    total += n;
  }
  return total;
}

// Closes a bare descriptor (a session that was never wrapped). Returns 0
// or -errno. close is not retried on EINTR: the descriptor is released
// either way, and a retry could close a reused number.
FPW_EXPORT int32_t fpw_close(int32_t fd) {
  return close(fd) == 0 ? 0 : -errno;
}

// Explicit close of a record: closes its fd, frees its buffer and the
// record. Returns 0 or -errno from close; the memory is freed regardless.
FPW_EXPORT int32_t fpw_reader_close(fpw_reader* reader) {
  int32_t result = 0;
  if (reader->fd >= 0 && close(reader->fd) != 0) {
    result = -errno;
  }
  free(reader->buffer);
  free(reader);
  return result;
}

// The NativeFinalizer callback (void f(void*)): the same cleanup, for a
// record whose Dart owner was collected or whose isolate died.
FPW_EXPORT void fpw_reader_finalize(void* reader) {
  fpw_reader_close((fpw_reader*)reader);
}
