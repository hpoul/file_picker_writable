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

    // A listing's shared prefix plus an entry's encoded name is exactly the
    // full identifier, for any parent and name.
    // Compared as UTF-8 bytes: Swift's == is canonical equivalence and would
    // hide a byte difference.
    for (parent, name) in [
      ("", "trip.json"), ("", ".howitwent"), ("media", "clip.mp4"),
      ("Trips/2026", "ü 日本"), ("a%2Fb", "50% off"), ("x:y", "e\u{301}:z"),
      ("", "a?b"), ("", "a#b"), ("q?", "a;b"), ("", "a+b"),
      ("", "\u{301}leading-mark"), ("e\u{301}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
      ("", "u\u{308}"), ("", "\u{FC}"),
    ] {
      let composed = ChildIdentifier.listingPrefix(root: root, parentPath: parent)
        + ChildIdentifier.encode(name)
      let full = ChildIdentifier.make(root: root, path: ChildIdentifier.join(parent, name))
      check(Array(composed.utf8) == Array(full.utf8), "prefix + suffix == make (bytes) for \(parent)/\(name)")
      check(
        parsedPath(composed).map { Array($0.utf8) } == Array(ChildIdentifier.join(parent, name).utf8),
        "composed parses back byte-identical for \(parent)/\(name)"
      )
    }
    // Decomposed and precomposed ü stay distinct identifiers (no normalization).
    check(
      Array(ChildIdentifier.make(root: root, path: "u\u{308}").utf8)
        != Array(ChildIdentifier.make(root: root, path: "\u{FC}").utf8),
      "no Unicode normalization in identifiers"
    )

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

    // child(): what createDirectory and moveEntry mint for a new entry is
    // exactly what a listing of its parent would hand out.
    let rootURL = URL(fileURLWithPath: "/picked")
    let picked = ResolvedIdentifier(url: rootURL, scopeURL: rootURL, isStale: false, rootBookmark: root, relativePath: "")
    let tour = picked.child("2026 tour")
    check(tour.relativePath == "2026 tour", "a root's child path is its name")
    check(tour.url.path == "/picked/2026 tour", "a root's child URL")
    check(tour.scopeURL == rootURL, "a child keeps the root's scope")
    let clip = tour.child("clip:1.mp4")
    check(clip.relativePath == "2026 tour/clip:1.mp4", "a grandchild path joins with /")
    check(
      clip.identifier(withRoot: root)
        == ChildIdentifier.listingPrefix(root: root, parentPath: "2026 tour") + ChildIdentifier.encode("clip:1.mp4"),
      "child() mints the listing's identifier"
    )

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
      // F1: `..` in a link target reached through a symlinked parent. The
      // kernel resolves root/t/link3 to outside/link3target.
      try fm.createDirectory(at: outside.appendingPathComponent("y"), withIntermediateDirectories: true)
      try fm.createSymbolicLink(
        atPath: rootURL.appendingPathComponent("t").path,
        withDestinationPath: outside.appendingPathComponent("y").path
      )
      try fm.createSymbolicLink(
        atPath: outside.appendingPathComponent("y/link3").path,
        withDestinationPath: "../link3target"
      )
      // Links in the middle of an existing path, followed by an existing file.
      try fm.createDirectory(at: rootURL.appendingPathComponent("d2/sub"), withIntermediateDirectories: true)
      fm.createFile(atPath: rootURL.appendingPathComponent("d2/sub/file.txt").path, contents: Data())
      fm.createFile(atPath: outside.appendingPathComponent("existing.txt").path, contents: Data())
      try fm.createSymbolicLink(atPath: rootURL.appendingPathComponent("mid").path, withDestinationPath: "d2")
      try fm.createSymbolicLink(atPath: rootURL.appendingPathComponent("mid2").path, withDestinationPath: "../outside")
      try fm.createSymbolicLink(atPath: rootURL.appendingPathComponent("d/back").path, withDestinationPath: "../d2")
      try fm.createSymbolicLink(atPath: rootURL.appendingPathComponent("selfrel").path, withDestinationPath: "../root")
      // Roots that are themselves symlinks.
      try fm.createSymbolicLink(atPath: base.appendingPathComponent("rootlink").path, withDestinationPath: "root")
      try fm.createSymbolicLink(atPath: base.appendingPathComponent("looproot").path, withDestinationPath: "looproot")
    } catch {
      check(false, "containment fixture: \(error)")
      return
    }
    func resolved(_ path: String, scope: URL = rootURL) -> ResolvedIdentifier {
      ResolvedIdentifier(
        url: path.isEmpty
          ? scope
          : ChildIdentifier.components(of: path).reduce(scope) { $0.appendingPathComponent($1) },
        scopeURL: scope,
        isStale: false,
        rootBookmark: root,
        relativePath: path
      )
    }
    check(!resolved("t/link3").isContained, "F1: `..` through a symlinked parent")
    check(!resolved("t/link3/new").isContained, "F1: a create through it")
    check(!resolved("t").isContained, "a symlink to a directory outside")
    check(resolved("mid/sub/file.txt").isContained, "a link in the middle, staying inside")
    check(!resolved("mid2/existing.txt").isContained, "a link in the middle, leading outside")
    check(resolved("d/back/sub/file.txt").isContained, "`..` in a link target that stays inside")
    check(!resolved("selfrel").isContained, "a child resolving to the root itself is refused (conservative)")
    check(resolved("selfrel/d").isContained, "below the root through a link to the root is inside")
    let rootLink = base.appendingPathComponent("rootlink")
    check(resolved("d", scope: rootLink).isContained, "a root that is itself a symlink")
    check(!resolved("out", scope: rootLink).isContained, "escape from a symlinked root")
    check(!resolved("x", scope: base.appendingPathComponent("looproot")).isContained, "F2: a looping root")
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
