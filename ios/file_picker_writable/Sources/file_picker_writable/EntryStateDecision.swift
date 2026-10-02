import Foundation

/// `entryState`'s answers, as Dart's `EntryState` reads them.
enum EntryState {
  static let readable = "readable"
  static let volumeAbsent = "volume-absent"
  static let permissionLost = "permission-lost"
  static let notFound = "not-found"
  static let notAFile = "not-a-file"
}

/// `entryState`'s decision (scope-registry-plan §9) over injected probes,
/// so the order is pinned by host tests rather than by device runs alone.
/// The first answer wins: the grant, the picked root's reachability (a
/// root that is gone reads as a volume that is), the entry, and a real
/// open. A probe that throws is loud: only a provably missing file is
/// "gone", never a failing drive's EIO.
enum EntryStateDecision {
  enum Reach {
    case reachable
    case gone
  }

  enum Opened: Equatable {
    /// A regular file, opened and up to one byte read (0 at end of file).
    case regular(bytesRead: Int)
    /// Anything else: a directory (through a symlink, too), a FIFO, a device.
    case notRegular
    /// ENOENT or ENOTDIR from the open.
    case gone
    /// EACCES or EPERM from the open.
    case refused
  }

  struct Probes {
    /// Resolves the identifier and starts its scope: false when either fails.
    var grant: () throws -> Bool
    /// The picked root.
    var root: () throws -> Reach
    /// The entry: inside its root, outside the Trash, and reachable.
    var entry: () throws -> Reach
    /// [probeOpen] on the entry.
    var open: () throws -> Opened
  }

  static func decide(_ probes: Probes) throws -> String {
    guard try probes.grant() else {
      return EntryState.permissionLost
    }
    guard try probes.root() == .reachable else {
      return EntryState.volumeAbsent
    }
    guard try probes.entry() == .reachable else {
      return EntryState.notFound
    }
    switch try probes.open() {
    case .regular:
      return EntryState.readable
    case .notRegular:
      return EntryState.notAFile
    case .refused:
      return EntryState.permissionLost
    case .gone:
      // Gone since the checks: the entry alone, or its root with it.
      return try probes.root() == .reachable ? EntryState.notFound : EntryState.volumeAbsent
    }
  }

  /// `checkResourceIsReachable` as a [Reach]: `.gone` only for a missing
  /// file (Cocoa's no-such-file codes, or POSIX ENOENT/ENOTDIR beneath);
  /// anything else, such as EIO or ENOTCONN from a failing drive, throws.
  static func reach(_ url: URL) throws -> Reach {
    do {
      return try url.checkResourceIsReachable() ? .reachable : .gone
    } catch let error as NSError where isMissing(error) {
      return .gone
    }
  }

  /// A POSIX error anywhere in the chain decides (a no-such-file code
  /// wrapping EIO is never missing); without one, Cocoa's own code.
  static func isMissing(_ error: NSError) -> Bool {
    var next: NSError? = error
    while let current = next {
      if current.domain == NSPOSIXErrorDomain {
        return current.code == Int(ENOENT) || current.code == Int(ENOTDIR)
      }
      next = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return error.domain == NSCocoaErrorDomain &&
      (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
  }

  /// A system call that failed outside the answers [Opened] gives.
  struct SyscallFailure: Error {
    let call: String
    let code: Int32
  }

  /// Opens `path`, checks it is a regular file, reads up to one byte and closes
  /// it. `O_NONBLOCK` so a FIFO cannot hold the open until a writer comes;
  /// a regular file ignores it.
  static func probeOpen(_ path: String) throws -> Opened {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else {
      let code = errno
      switch code {
      case ENOENT, ENOTDIR:
        return .gone
      case EACCES, EPERM:
        return .refused
      default:
        throw SyscallFailure(call: "open", code: code)
      }
    }
    defer {
      close(fd)
    }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw SyscallFailure(call: "fstat", code: errno)
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      return .notRegular
    }
    var byte: UInt8 = 0
    let bytesRead = read(fd, &byte, 1)
    guard bytesRead >= 0 else {
      throw SyscallFailure(call: "read", code: errno)
    }
    return .regular(bytesRead: bytesRead)
  }
}
