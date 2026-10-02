// Copyright (c) 2019 Herbert Poul. MIT License, see LICENSE.
//
// The byte path of doc/large-file-reads-plan.md §5 and, for writes,
// doc/tree-writes-plan.md §5: the few syscalls Dart makes on a detached
// file descriptor, wrapped so each returns -errno from
// the call itself (an errno read through a second FFI call can be stale:
// the VM may make syscalls of its own in between) and retries EINTR
// inside.
//
// Two kinds of native memory, each with one owner:
// - Read buffers belong to Dart: it wraps them with asTypedList and
//   fpw_buffer_free as the finalizer, so every view of a buffer keeps it
//   alive. A view kept past the next read or past close reads stale bytes,
//   never freed memory.
// - An owner record per adopted descriptor, released by explicit close or
//   by the NativeFinalizer backstop. The records are registered in a
//   process-wide table, so a descriptor already owned (a handoff record
//   consumed twice) is refused instead of closed twice.
//
// POSIX only: hook/build.dart skips Windows, where openRead is unsupported.

// One pread signature on every platform: 64-bit offsets on 32-bit Android
// too (pread64 there), plain pread on Darwin and 64-bit Linux.
#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#define FPW_EXPORT __attribute__((visibility("default"))) __attribute__((used))

FPW_EXPORT uint8_t* fpw_buffer_new(int64_t length) {
  return malloc(length > 0 ? (size_t)length : 1);
}

// The buffer finalizer (void f(void*)).
FPW_EXPORT void fpw_buffer_free(void* buffer) {
  free(buffer);
}

typedef struct {
  int32_t fd;
} fpw_owner;

static pthread_mutex_t owned_lock = PTHREAD_MUTEX_INITIALIZER;
static int32_t* owned_fds = NULL;
static size_t owned_count = 0;
static size_t owned_capacity = 0;

// Registers fd as owned. EBUSY when it already is, ENOMEM, or 0.
static int owned_add(int32_t fd) {
  int result = 0;
  pthread_mutex_lock(&owned_lock);
  for (size_t i = 0; i < owned_count; i++) {
    if (owned_fds[i] == fd) {
      result = EBUSY;
      goto done;
    }
  }
  if (owned_count == owned_capacity) {
    size_t capacity = owned_capacity == 0 ? 16 : owned_capacity * 2;
    int32_t* grown = realloc(owned_fds, capacity * sizeof(int32_t));
    if (grown == NULL) {
      result = ENOMEM;
      goto done;
    }
    owned_fds = grown;
    owned_capacity = capacity;
  }
  owned_fds[owned_count++] = fd;
done:
  pthread_mutex_unlock(&owned_lock);
  return result;
}

static void owned_remove(int32_t fd) {
  pthread_mutex_lock(&owned_lock);
  for (size_t i = 0; i < owned_count; i++) {
    if (owned_fds[i] == fd) {
      owned_fds[i] = owned_fds[--owned_count];
      break;
    }
  }
  pthread_mutex_unlock(&owned_lock);
}

// A fresh, empty owner record, or NULL when out of memory. Its pointer is
// passed around as a pointer, never as a number: Android heap pointers
// carry a tag in the top byte, so they are negative as an int64.
FPW_EXPORT fpw_owner* fpw_owner_new(void) {
  return malloc(sizeof(fpw_owner));
}

// Makes `owner` the owner of fd: 0, or -EBUSY when another record owns fd
// already, or -ENOMEM. On failure `owner` is freed and fd stays the
// caller's.
FPW_EXPORT int32_t fpw_adopt(fpw_owner* owner, int32_t fd) {
  int error = owned_add(fd);
  if (error != 0) {
    free(owner);
    return -error;
  }
  owner->fd = fd;
  return 0;
}

// Reads up to `length` bytes at `offset` into `buffer`, looping over short
// reads until `length` or end of file. Returns the byte count (0 at end of
// file) or -errno.
FPW_EXPORT int64_t fpw_pread_full(int32_t fd, uint8_t* buffer, int64_t offset, int64_t length) {
  int64_t total = 0;
  while (total < length) {
    ssize_t n = pread(fd, buffer + total, (size_t)(length - total), (off_t)(offset + total));
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
FPW_EXPORT int64_t fpw_read_full(int32_t fd, uint8_t* buffer, int64_t length) {
  int64_t total = 0;
  while (total < length) {
    ssize_t n = read(fd, buffer + total, (size_t)(length - total));
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

// Waits until fd takes more bytes (a non-blocking pipe that is full).
// 0, or -errno.
static int wait_writable(int32_t fd) {
  struct pollfd entry = {.fd = fd, .events = POLLOUT, .revents = 0};
  while (poll(&entry, 1, -1) < 0) {
    if (errno != EINTR) {
      return -errno;
    }
  }
  return 0;
}

// Writes `length` bytes from `buffer` at `offset`, looping over short
// writes. Returns the bytes written, or -errno when nothing was written:
// once some bytes are down, an error ends the loop and the count is
// returned, so the caller never loses track of what landed (it re-issues
// the rest and sees the real errno then). A write that returns 0 also ends
// the loop short; the caller reports fewer bytes than asked, so a 0 never
// spins. EAGAIN (a non-blocking descriptor that is full) waits for room.
FPW_EXPORT int64_t fpw_pwrite_full(int32_t fd, const uint8_t* buffer, int64_t offset, int64_t length) {
  int64_t total = 0;
  while (total < length) {
    ssize_t n = pwrite(fd, buffer + total, (size_t)(length - total), (off_t)(offset + total));
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        int waited = wait_writable(fd);
        if (waited == 0) {
          continue;
        }
        return total > 0 ? total : waited;
      }
      return total > 0 ? total : -(int64_t)errno;
    }
    if (n == 0) {
      break;
    }
    total += n;
  }
  return total;
}

// The same for a non-seekable descriptor (a pipe): sequential write.
FPW_EXPORT int64_t fpw_write_full(int32_t fd, const uint8_t* buffer, int64_t length) {
  int64_t total = 0;
  while (total < length) {
    ssize_t n = write(fd, buffer + total, (size_t)(length - total));
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        int waited = wait_writable(fd);
        if (waited == 0) {
          continue;
        }
        return total > 0 ? total : waited;
      }
      return total > 0 ? total : -(int64_t)errno;
    }
    if (n == 0) {
      break;
    }
    total += n;
  }
  return total;
}

// Makes the file's bytes durable: 1 when the drive was told to write its
// cache through (Apple's F_FULLFSYNC: plain fsync there only hands the
// bytes to the drive), 0 for plain fsync, or -errno. F_FULLFSYNC falls
// back to fsync only where the volume refuses it (ENOTSUP, EINVAL: some
// exFAT and network volumes), as SQLite does; any other failure is loud.
FPW_EXPORT int32_t fpw_fsync(int32_t fd) {
#if defined(__APPLE__)
  while (fcntl(fd, F_FULLFSYNC) != 0) {
    if (errno == EINTR) {
      continue;
    }
    if (errno != ENOTSUP && errno != EINVAL) {
      return -errno;
    }
    goto plain;
  }
  return 1;
plain:
#endif
  while (fsync(fd) != 0) {
    if (errno != EINTR) {
      return -errno;
    }
  }
  return 0;
}

// Closes a bare descriptor (a session that was never wrapped). Returns 0
// or -errno. close is not retried on EINTR: the descriptor is released
// either way, and a retry could close a reused number.
FPW_EXPORT int32_t fpw_close(int32_t fd) {
  return close(fd) == 0 ? 0 : -errno;
}

// Explicit close of an owner record: unregisters and closes its fd, frees
// the record. Returns 0 or -errno from close; the record is freed
// regardless. Unregistered before the close, so a number the kernel hands
// out again is never refused as busy; the cost is that a second adopt of a
// double-consumed record racing this very window is not caught.
FPW_EXPORT int32_t fpw_release(fpw_owner* owner) {
  int32_t fd = owner->fd;
  free(owner);
  owned_remove(fd);
  return close(fd) == 0 ? 0 : -errno;
}

// The NativeFinalizer callback (void f(void*)): the same release, for a
// record whose Dart owner was collected or whose isolate died.
FPW_EXPORT void fpw_release_finalize(void* owner) {
  fpw_release((fpw_owner*)owner);
}
