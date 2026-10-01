// Host tests for ChildIdentifier: the traversal boundary of iOS child
// identifiers (doc/tree-traversal-plan.md §5). Foundation only, so it
// builds with plain swiftc next to the source file; run it with
// tool/swift_unit_tests.sh. Exits non-zero on the first failure count.

import Foundation

@main
struct ChildIdentifierTests {
  static var failures = 0

  static func check(_ condition: Bool, _ label: String) {
    if !condition {
      failures += 1
      print("FAIL: \(label)")
    }
  }

  static func rejects(_ identifier: String, _ label: String) {
    do {
      _ = try ChildIdentifier.parse(identifier)
      check(false, "\(label) should be rejected: \(identifier)")
    } catch {
      check(error is ChildIdentifier.Malformed, "\(label) throws Malformed")
    }
  }

  /// True when parse succeeds and says "no child prefix" (nil), as opposed
  /// to throwing.
  static func isNotAChild(_ identifier: String) -> Bool {
    do {
      return try ChildIdentifier.parse(identifier) == nil
    } catch {
      return false
    }
  }

  static func parsedPath(_ identifier: String) -> String? {
    (try? ChildIdentifier.parse(identifier))??.path
  }

  static let root = "QUJD"  // base64 of "ABC"

  static func main() {
    // Round trips, including non-ASCII, combining marks and a literal %.
    for path in ["a", "a/b c", "Trips/2026/ü 日本", "e\u{301}/x", "a%2Fb", "50% off/b:c"] {
      let id = ChildIdentifier.make(root: root, path: path)
      check(parsedPath(id) == path, "round trip \(path)")
      check(try! ChildIdentifier.parse(id)!.root == root, "root survives \(path)")
    }

    // %2F decodes to a separator, never a literal.
    let raw = ChildIdentifier.prefix + root + ":a%2Fb"
    check(parsedPath(raw) == "a/b", "%2F is a separator")
    check(ChildIdentifier.components(of: "a/b") == ["a", "b"], "a/b splits in two")

    // %252F is a literal %2F inside one component.
    let literal = ChildIdentifier.make(root: root, path: "a%2Fb")
    check(literal.hasSuffix(":a%252Fb"), "a literal % is encoded as %25")
    check(ChildIdentifier.components(of: parsedPath(literal)!) == ["a%2Fb"], "%252F stays one component")

    // The traversal boundary: nothing that could leave the root.
    let p = ChildIdentifier.prefix + root + ":"
    rejects(p, "empty path")
    rejects(p + "/abs", "absolute path")
    rejects(p + "a//b", "empty component")
    rejects(p + ".", "dot")
    rejects(p + "..", "dot-dot")
    rejects(p + "a/../b", "inner dot-dot")
    rejects(p + "a/", "trailing slash")
    rejects(p + "a%00b", "%00 (NUL)")
    rejects(p + "%2E%2E", "encoded dot-dot")
    rejects(p + "a%2F..%2Fb", "encoded traversal")
    rejects(p + "%ZZ", "invalid percent-encoding")

    // The root part must be a non-empty bookmark.
    rejects(ChildIdentifier.prefix + ":a", "empty root")
    rejects(ChildIdentifier.prefix + "@@@:a", "non-base64 root")
    rejects(ChildIdentifier.prefix + root, "no path separator")

    // An unknown version is not ours: parse leaves it to the bookmark
    // decoder, which refuses it (':' is not base64), so it stays loud.
    let v2 = "fpwchild2:" + root + ":a"
    check(isNotAChild(v2), "unknown prefix is not parsed as a child")
    check(Data(base64Encoded: v2) == nil, "unknown prefix is no bookmark either")
    check(isNotAChild(root), "a plain bookmark is not a child")

    // The leaf rule works on scalars: a combining mark cannot hide '/'.
    check(!ChildIdentifier.isLeafName("/\u{301}"), "slash plus combining mark is not a leaf")
    check(ChildIdentifier.isLeafName("e\u{301}"), "a combining mark in a name is fine")
    check(ChildIdentifier.isLeafName(".howitwent"), "dotfiles are leaves")
    check(ChildIdentifier.components(of: "a/\u{301}b") == ["a", "\u{301}b"], "scalar split keeps the separator")

    containment()

    if failures > 0 {
      print("\(failures) failure(s)")
      exit(1)
    }
    print("ChildIdentifier: all checks passed")
  }

  /// A symlink inside the root that points out of it must not count as
  /// contained; ordinary children must.
  static func containment() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("fpw-child-id-\(UUID().uuidString)")
    let rootURL = base.appendingPathComponent("root")
    let outside = base.appendingPathComponent("outside")
    defer {
      try? fm.removeItem(at: base)
    }
    do {
      try fm.createDirectory(at: rootURL.appendingPathComponent("d"), withIntermediateDirectories: true)
      try fm.createDirectory(at: outside, withIntermediateDirectories: true)
      try fm.createSymbolicLink(at: rootURL.appendingPathComponent("out"), withDestinationURL: outside)
      // Dangling: the targets do not exist, so a create would make them.
      try fm.createSymbolicLink(
        atPath: rootURL.appendingPathComponent("dangling").path,
        withDestinationPath: outside.appendingPathComponent("new").path
      )
      try fm.createSymbolicLink(
        atPath: rootURL.appendingPathComponent("dangling-rel").path,
        withDestinationPath: "../outside/new"
      )
      try fm.createSymbolicLink(
        atPath: rootURL.appendingPathComponent("inside-link").path,
        withDestinationPath: "d/new"
      )
      try fm.createSymbolicLink(
        atPath: rootURL.appendingPathComponent("loop").path,
        withDestinationPath: "loop"
      )
    } catch {
      check(false, "containment fixture: \(error)")
      return
    }
    func resolved(_ path: String) -> ResolvedIdentifier {
      ResolvedIdentifier(
        url: path.isEmpty
          ? rootURL
          : ChildIdentifier.components(of: path).reduce(rootURL) { $0.appendingPathComponent($1) },
        scopeURL: rootURL,
        isStale: false,
        rootBookmark: root,
        relativePath: path
      )
    }
    check(resolved("").isContained, "the root itself")
    check(resolved("d").isContained, "a child directory")
    check(resolved("d/new.txt").isContained, "a not-yet-existing child")
    check(!resolved("out").isContained, "a symlink out of the root")
    check(!resolved("out/x").isContained, "a path through a symlink out of the root")
    check(!resolved("dangling").isContained, "a dangling absolute symlink out of the root")
    check(!resolved("dangling-rel").isContained, "a dangling relative symlink out of the root")
    check(!resolved("dangling/x").isContained, "a path through a dangling symlink")
    check(resolved("inside-link").isContained, "a dangling symlink that stays inside")
    check(!resolved("loop").isContained, "a symlink loop")
  }
}
