import Foundation

/// What proves that the file under a name is the one a write session
/// created (doc/tree-writes-plan.md §5; #72 review M1/M1b), so that an abort
/// never deletes a file that took the partial's name since.
///
/// An inode alone is not evidence everywhere: APFS and HFS keep file IDs
/// stable and never reuse them, but FAT-family volumes derive them from the
/// file's first cluster (msdosfs: every empty file shares one ID, and freed
/// clusters are reused first-fit). So the birth time is part of the
/// identity on every volume, and the inode only where the file system keeps
/// it stable. A file born after the session's create fails either way.
/// Without a birth time there is no identity at all (`init` fails): a
/// volume that reports none would otherwise reduce the check to "same
/// device", and an abort keeps the partial instead.
///
/// Foundation-only on purpose: `ios/test/FileIdentityTests.swift` pins the
/// decision on the host (`tool/swift_unit_tests.sh`).
struct FileIdentity: Equatable {
  let device: Int64
  let inode: UInt64
  /// Birth time in nanoseconds since the epoch; never 0.
  let birth: Int64
  /// Whether this volume's inode numbers identify a file (APFS, HFS).
  let inodesStable: Bool

  /// FAT and exFAT store create times to 10 ms, and the in-memory value is
  /// already the rounded one, so a stat after create and one after a
  /// remount agree exactly; the slack only covers rounding between layers.
  /// It is also the window in which a file created right after ours,
  /// under the same name, on a volume without stable inodes, would pass.
  static let birthTolerance: Int64 = 50_000_000

  init(device: Int64, inode: UInt64, birth: Int64, inodesStable: Bool) {
    self.device = device
    self.inode = inode
    self.birth = birth
    self.inodesStable = inodesStable
  }

  /// Nil when `info` carries no birth time (0): no identity, no delete.
  init?(_ info: stat, inodesStable: Bool) {
    let birth = Self.birthNanos(info)
    guard birth > 0 else {
      return nil
    }
    self.init(
      device: Int64(info.st_dev),
      inode: UInt64(info.st_ino),
      birth: birth,
      inodesStable: inodesStable
    )
  }

  /// The form a session carries: `device:inode:birth:stable`.
  var encoded: String {
    "\(device):\(inode):\(birth):\(inodesStable ? 1 : 0)"
  }

  init?(encoded: String) {
    let parts = encoded.split(separator: ":")
    guard parts.count == 4,
      let device = Int64(parts[0]),
      let inode = UInt64(parts[1]),
      let birth = Int64(parts[2]),
      birth > 0,
      let stable = Int(parts[3])
    else {
      return nil
    }
    self.init(device: device, inode: inode, birth: birth, inodesStable: stable == 1)
  }

  /// Whether `info`, a stat taken now, is this file: the same device, a
  /// birth time within `birthTolerance`, and the same inode where inodes
  /// are stable. Fails safe: a mismatch only keeps a partial.
  func matches(_ info: stat) -> Bool {
    guard let other = FileIdentity(info, inodesStable: inodesStable),
      other.device == device,
      abs(other.birth - birth) <= Self.birthTolerance
    else {
      return false
    }
    return !inodesStable || other.inode == inode
  }

  /// Strict: two stats of one regular file moments apart (the create's
  /// descriptor and its name): the same device, inode and exact birth
  /// time. A hard link to the file passes too; callers that pick one entry
  /// refuse when several do.
  static func sameFile(_ a: stat, _ b: stat) -> Bool {
    (a.st_mode & S_IFMT) == S_IFREG && (b.st_mode & S_IFMT) == S_IFREG
      && a.st_dev == b.st_dev && a.st_ino == b.st_ino && birthNanos(a) == birthNanos(b)
  }

  static func birthNanos(_ info: stat) -> Int64 {
    Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec)
  }

  /// Whether the volume holding `fd` keeps inode numbers stable.
  static func inodesStable(fd: Int32) -> Bool {
    var volume = statfs()
    guard fstatfs(fd, &volume) == 0 else {
      return false
    }
    let type = withUnsafeBytes(of: &volume.f_fstypename) { raw in
      String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return type == "apfs" || type == "hfs"
  }
}
