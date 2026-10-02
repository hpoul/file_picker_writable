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
///
/// Foundation-only on purpose: `ios/test/FileIdentityTests.swift` pins the
/// decision on the host (`tool/swift_unit_tests.sh`).
struct FileIdentity: Equatable {
  let device: Int64
  let inode: UInt64
  /// Birth time in nanoseconds since the epoch.
  let birth: Int64
  /// Whether this volume's inode numbers identify a file (APFS, HFS).
  let inodesStable: Bool

  /// FAT stores create times coarsely (2 s on some variants): a birth time
  /// read back later may differ by that much from the one read at create.
  static let birthTolerance: Int64 = 2_000_000_000

  init(device: Int64, inode: UInt64, birth: Int64, inodesStable: Bool) {
    self.device = device
    self.inode = inode
    self.birth = birth
    self.inodesStable = inodesStable
  }

  init(_ info: stat, inodesStable: Bool) {
    self.init(
      device: Int64(info.st_dev),
      inode: UInt64(info.st_ino),
      birth: Self.birthNanos(info),
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
    let other = FileIdentity(info, inodesStable: inodesStable)
    guard other.device == device, abs(other.birth - birth) <= Self.birthTolerance else {
      return false
    }
    return !inodesStable || other.inode == inode
  }

  /// Strict: the same device, inode and exact birth time. For two stats
  /// of one file moments apart (the create's descriptor and its name).
  func isSame(_ info: stat) -> Bool {
    self == FileIdentity(info, inodesStable: inodesStable)
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
