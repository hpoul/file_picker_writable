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
    let identity = FileIdentity(created, inodesStable: stable)
    check(FileIdentity(encoded: identity.encoded) == identity, "the encoded form round-trips")
    check(FileIdentity(encoded: "1:2:3") == nil, "a malformed form is refused")
    check(identity.isSame(lstatOf(partial)), "the name holds the descriptor's file (strict)")

    // Written to: still the same file.
    _ = write(fd, "0123456789", 10)
    close(fd)
    check(identity.matches(lstatOf(partial)), "a written partial still matches")

    // Renamed away, and a newcomer takes the name: never a match.
    let away = base.appendingPathComponent("moved-away").path
    check(rename(partial, away) == 0, "rename away")
    sleep(3)  // past the birth tolerance, as a newcomer created later is
    check(fm.createFile(atPath: partial, contents: Data("x".utf8)), "newcomer")
    check(!identity.matches(lstatOf(partial)), "a newcomer under the name does not match")
    check(identity.matches(lstatOf(away)), "the renamed partial still matches")

    // Where inodes are not evidence (FAT), the birth time still is.
    let fatStyle = FileIdentity(
      device: identity.device, inode: 999, birth: identity.birth, inodesStable: false)
    check(fatStyle.matches(lstatOf(away)), "unstable inodes: device and birth time decide")
    check(!fatStyle.matches(lstatOf(partial)), "unstable inodes: a later-born newcomer still fails")
    let otherDevice = FileIdentity(
      device: identity.device + 1, inode: identity.inode, birth: identity.birth, inodesStable: true)
    check(!otherDevice.matches(lstatOf(away)), "another device never matches")

    if failures > 0 {
      print("\(failures) failure(s)")
      exit(1)
    }
    print("FileIdentity: all checks passed")
  }
}
