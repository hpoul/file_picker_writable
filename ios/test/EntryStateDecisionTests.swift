// Host tests for EntryStateDecision: the order of entryState's checks,
// which reachability failures count as gone, and what the open probe
// answers for each kind of file (doc/scope-registry-plan.md §9).
// Foundation only; run with tool/swift_unit_tests.sh. Exits non-zero on
// the first failure count.

import Foundation

@main
struct EntryStateDecisionTests {
  static var failures = 0

  static func check(_ condition: Bool, _ label: String) {
    if !condition {
      failures += 1
      print("FAIL: \(label)")
    }
  }

  struct Loud: Error {}

  /// Probes answering from fixed values, recording the order asked; the
  /// root answers in turn, so the recheck after a failed open can differ.
  final class Fake {
    var asked: [String] = []
    var grant = true
    var roots: [EntryStateDecision.Reach] = [.reachable]
    var entry: EntryStateDecision.Reach = .reachable
    var opened: EntryStateDecision.Opened = .regular(bytesRead: 1)
    var openThrows = false

    var probes: EntryStateDecision.Probes {
      EntryStateDecision.Probes(
        grant: {
          self.asked.append("grant")
          return self.grant
        },
        root: {
          self.asked.append("root")
          return self.roots.count > 1 ? self.roots.removeFirst() : self.roots[0]
        },
        entry: {
          self.asked.append("entry")
          return self.entry
        },
        open: {
          self.asked.append("open")
          if self.openThrows {
            throw Loud()
          }
          return self.opened
        }
      )
    }

    func decide() -> String? {
      try? EntryStateDecision.decide(probes)
    }
  }

  static func decisionOrder() {
    var fake = Fake()
    check(fake.decide() == EntryState.readable, "a regular file is readable")
    check(fake.asked == ["grant", "root", "entry", "open"], "every check, in order")

    fake = Fake()
    fake.grant = false
    fake.roots = [.gone]
    check(fake.decide() == EntryState.permissionLost, "the grant answers first")
    check(fake.asked == ["grant"], "nothing else is asked without a grant")

    fake = Fake()
    fake.roots = [.gone]
    fake.entry = .gone
    check(fake.decide() == EntryState.volumeAbsent, "the root answers before the entry")
    check(fake.asked == ["grant", "root"], "the entry is not asked under a gone root")

    fake = Fake()
    fake.entry = .gone
    check(fake.decide() == EntryState.notFound, "a gone entry is notFound")
    check(!fake.asked.contains("open"), "a gone entry is never opened")

    fake = Fake()
    fake.opened = .notRegular
    check(fake.decide() == EntryState.notAFile, "not a regular file is notAFile")

    fake = Fake()
    fake.opened = .refused
    check(fake.decide() == EntryState.permissionLost, "a refused open is permissionLost")

    fake = Fake()
    fake.opened = .gone
    check(fake.decide() == EntryState.notFound, "gone at the open, root still there: notFound")
    check(fake.asked == ["grant", "root", "entry", "open", "root"], "the root is asked again")

    fake = Fake()
    fake.opened = .gone
    fake.roots = [.reachable, .gone]
    check(fake.decide() == EntryState.volumeAbsent, "gone at the open with its root: volumeAbsent")

    fake = Fake()
    fake.openThrows = true
    check(fake.decide() == nil, "a failed open outside the answers is loud")
  }

  static func reachability(_ base: URL) {
    let fm = FileManager.default
    let file = base.appendingPathComponent("clip.mp4")
    fm.createFile(atPath: file.path, contents: Data([1, 2, 3]))
    check((try? EntryStateDecision.reach(file)) == .reachable, "an existing file is reachable")
    check(
      (try? EntryStateDecision.reach(base.appendingPathComponent("missing.mp4"))) == .gone,
      "a missing file is gone"
    )
    check(
      (try? EntryStateDecision.reach(file.appendingPathComponent("below"))) == .gone,
      "a path through a file (ENOTDIR) is gone"
    )

    let eio = NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileReadUnknownError,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))]
    )
    check(!EntryStateDecision.isMissing(eio), "EIO from a failing drive is never gone")
    let enoent = NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileReadUnknownError,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))]
    )
    check(EntryStateDecision.isMissing(enoent), "ENOENT beneath a Cocoa error is gone")
    let wrappedEIO = NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileReadNoSuchFileError,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))]
    )
    check(!EntryStateDecision.isMissing(wrappedEIO), "a no-such-file code wrapping EIO is never gone")
    check(
      EntryStateDecision.isMissing(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)),
      "a bare no-such-file code is gone"
    )
    check(
      !EntryStateDecision.isMissing(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))),
      "ENOTCONN is never gone"
    )
  }

  static func probes(_ base: URL) {
    let fm = FileManager.default
    func opened(_ path: String) -> EntryStateDecision.Opened? {
      try? EntryStateDecision.probeOpen(path)
    }

    let file = base.appendingPathComponent("clip.mp4").path
    // The byte read is what makes a failing first block loud: pinned here.
    check(opened(file) == .regular(bytesRead: 1), "a regular file reads one byte")
    let empty = base.appendingPathComponent("empty.mp4").path
    fm.createFile(atPath: empty, contents: Data())
    check(opened(empty) == .regular(bytesRead: 0), "an empty regular file reads to end of file")

    let directory = base.appendingPathComponent("folder")
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    check(opened(directory.path) == .notRegular, "a directory is not regular")
    let link = base.appendingPathComponent("link-to-folder").path
    try? fm.createSymbolicLink(atPath: link, withDestinationPath: directory.path)
    check(opened(link) == .notRegular, "a symlink to a directory is not regular")

    let fifo = base.appendingPathComponent("fifo").path
    check(mkfifo(fifo, 0o644) == 0, "mkfifo")
    // Without O_NONBLOCK this open would wait for a writer forever.
    check(opened(fifo) == .notRegular, "a FIFO is not regular, and the open does not block")

    check(opened(base.appendingPathComponent("missing.mp4").path) == .gone, "ENOENT is gone")
    check(opened(file + "/below") == .gone, "ENOTDIR is gone")

    // Root opens a mode-0 file anyway.
    if geteuid() != 0 {
      let locked = base.appendingPathComponent("locked.mp4").path
      fm.createFile(atPath: locked, contents: Data([1]))
      chmod(locked, 0)
      check(opened(locked) == .refused, "EACCES is refused")
      chmod(locked, 0o644)
    }
  }

  static func main() {
    // A FIFO open that lost O_NONBLOCK hangs: fail the run instead.
    alarm(10)
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("fpw-entry-state-\(UUID().uuidString)")
    defer {
      try? fm.removeItem(at: base)
    }
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)

    decisionOrder()
    reachability(base)
    probes(base)

    if failures > 0 {
      print("EntryStateDecisionTests: \(failures) failed")
      exit(1)
    }
    print("EntryStateDecisionTests: all passed")
  }
}
