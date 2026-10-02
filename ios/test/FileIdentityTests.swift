// Host tests for FileIdentity: an abort deletes a partial only when the
// file under its name is provably the one the session created
// (doc/tree-writes-plan.md §5). Foundation only; run with
// tool/swift_unit_tests.sh. Exits non-zero on the first failure count.

import Foundation

@main
struct FileIdentityTests {
  static var failures = 0

  static func check(_ condition: Bool, _ label: String) {
    if !condition {
      failures += 1
      print("FAIL: \(label)")
    }
  }

  static func lstatOf(_ path: String) -> stat {
    var info = stat()
    _ = lstat(path, &info)
    return info
  }

  static func main() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("fpw-identity-\(UUID().uuidString)")
    defer {
      try? fm.removeItem(at: base)
    }
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    let partial = base.appendingPathComponent("clip.mp4.writing").path

    // The session's create.
    let fd = open(partial, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    check(fd >= 0, "create")
    var created = stat()
    check(fstat(fd, &created) == 0, "fstat")
    let stable = FileIdentity.inodesStable(fd: fd)
    check(stable, "the host temp volume (APFS) keeps inodes stable")
    guard let identity = FileIdentity(created, inodesStable: stable) else {
      check(false, "APFS reports a birth time")
      exit(1)
    }
    check(FileIdentity(encoded: identity.encoded) == identity, "the encoded form round-trips")
    check(FileIdentity(encoded: "1:2:3") == nil, "a malformed form is refused")
    check(FileIdentity(encoded: "1:2:0:0") == nil, "an encoded form without a birth time is refused")
    check(FileIdentity.sameFile(created, lstatOf(partial)), "the name holds the descriptor's file (strict)")

    // No birth time, no identity: an abort then keeps the partial.
    var noBirth = created
    noBirth.st_birthtimespec = timespec(tv_sec: 0, tv_nsec: 0)
    check(FileIdentity(noBirth, inodesStable: false) == nil, "no birth time: no identity")
    check(!identity.matches(noBirth), "a stat without a birth time never matches")

    // Written to: still the same file.
    _ = write(fd, "0123456789", 10)
    close(fd)
    check(identity.matches(lstatOf(partial)), "a written partial still matches")

    // Renamed away, and a newcomer takes the name: never a match once it
    // is born outside the tolerance.
    let away = base.appendingPathComponent("moved-away").path
    check(rename(partial, away) == 0, "rename away")
    usleep(200_000)  // 200 ms, past the 50 ms tolerance
    check(fm.createFile(atPath: partial, contents: Data("x".utf8)), "newcomer")
    let newcomer = lstatOf(partial)
    check(!identity.matches(newcomer), "a newcomer under the name does not match")
    check(identity.matches(lstatOf(away)), "the renamed partial still matches")

    // Where inodes are not evidence (FAT), the birth time decides, within
    // the tolerance: written down, not hidden.
    let fatStyle = FileIdentity(
      device: identity.device, inode: 999, birth: identity.birth, inodesStable: false)
    check(fatStyle.matches(lstatOf(away)), "unstable inodes: device and birth time decide")
    check(!fatStyle.matches(newcomer), "unstable inodes: a newcomer born 200 ms later fails")
    let window = FileIdentity(
      device: identity.device, inode: 999,
      birth: FileIdentity.birthNanos(newcomer) - 40_000_000, inodesStable: false)
    check(window.matches(newcomer), "the accepted window: a newcomer born within 50 ms passes on FAT")
    let otherDevice = FileIdentity(
      device: identity.device + 1, inode: identity.inode, birth: identity.birth, inodesStable: true)
    check(!otherDevice.matches(lstatOf(away)), "another device never matches")

    // A hard link has the same identity; a directory never is "the file".
    let link = base.appendingPathComponent("hard-link").path
    check(link_(away, link), "hard link")
    check(FileIdentity.sameFile(lstatOf(away), lstatOf(link)), "a hard link is the same file")
    check(!FileIdentity.sameFile(lstatOf(base.path), lstatOf(base.path)), "a directory is never matched")

    if failures > 0 {
      print("\(failures) failure(s)")
      exit(1)
    }
    print("FileIdentity: all checks passed")
  }

  static func link_(_ from: String, _ to: String) -> Bool {
    Darwin.link(from, to) == 0
  }
}
