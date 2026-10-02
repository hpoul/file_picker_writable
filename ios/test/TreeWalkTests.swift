// Host tests for TreeWalk: the recursive delete never follows a symlink,
// and the real-path helpers say where an entry is by the kernel
// (doc/tree-writes-plan.md §5). Foundation only; run with
// tool/swift_unit_tests.sh. Exits non-zero on the first failure count.

import Foundation

@main
struct TreeWalkTests {
  static var failures = 0

  static func check(_ condition: Bool, _ label: String) {
    if !condition {
      failures += 1
      print("FAIL: \(label)")
    }
  }

  static func main() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("fpw-tree-walk-\(UUID().uuidString)")
    let root = base.appendingPathComponent("root")
    let sibling = base.appendingPathComponent("sibling")
    defer {
      try? fm.removeItem(at: base)
    }
    do {
      try fm.createDirectory(at: root.appendingPathComponent("tree/a/inner"), withIntermediateDirectories: true)
      try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
      fm.createFile(atPath: sibling.appendingPathComponent("canary").path, contents: Data("alive".utf8))
      fm.createFile(atPath: root.appendingPathComponent("tree/a/file.bin").path, contents: Data())
      // Links to a directory outside, at two depths, and one back to root.
      try fm.createSymbolicLink(atPath: root.appendingPathComponent("tree/out").path, withDestinationPath: "../../sibling")
      try fm.createSymbolicLink(atPath: root.appendingPathComponent("tree/a/inner/out2").path, withDestinationPath: sibling.path)
      try fm.createSymbolicLink(atPath: root.appendingPathComponent("tree/up").path, withDestinationPath: "..")
    } catch {
      check(false, "fixture: \(error)")
    }

    let tree = root.appendingPathComponent("tree")
    let out = tree.appendingPathComponent("out")
    check(TreeWalk.isSymlink(out), "a link to a directory is a symlink")
    check((try? TreeWalk.isRealDirectory(out)) == false, "a link to a directory is not a real directory")
    check((try? TreeWalk.isRealDirectory(tree)) == true, "a directory is one")

    // Real paths: an entry's own path, and for a link the link itself.
    let rootReal = TreeWalk.realPath(root)!
    check(TreeWalk.realEntryPath(out) == rootReal + "/tree/out", "a link's entry path is the link, not its target")
    check(TreeWalk.realPath(out)?.hasSuffix("/sibling") == true, "realPath follows the link")
    check(TreeWalk.realPath(tree.appendingPathComponent("a/..")) == rootReal + "/tree", "realPath resolves ..")
    check(TreeWalk.realPath(tree.appendingPathComponent("missing")) == nil, "nothing there resolves to nil")

    // FAT's trailing-dot/space rule, as on Android.
    for path in ["a/.. ", "a/. .", "a/...", " ", "a/ /b"] {
      check(TreeWalk.hasStrippableComponent(path), "\"\(path)\" has a strippable component")
    }
    for path in ["a", "a/.howitwent", "a. b/c", "trip.json."] {
      check(!TreeWalk.hasStrippableComponent(path), "\"\(path)\" is ordinary")
    }

    // The walk: everything below tree goes, the links as links; nothing
    // the links point at is touched.
    do {
      let children = try fm.contentsOfDirectory(at: tree, includingPropertiesForKeys: nil, options: [])
      try TreeWalk.deleteChildren(children)
      try TreeWalk.removeIfPresent(tree)
    } catch {
      check(false, "walk: \(error)")
    }
    check(!fm.fileExists(atPath: tree.path), "the tree is gone")
    check(fm.fileExists(atPath: root.path), "the root behind the `up` link survives")
    check(
      (try? String(contentsOf: sibling.appendingPathComponent("canary"), encoding: .utf8)) == "alive",
      "the canary behind the links survives"
    )
    check((try? TreeWalk.removeIfPresent(tree)) != nil, "removing something gone is success")

    if failures > 0 {
      print("\(failures) failure(s)")
      exit(1)
    }
    print("TreeWalk: all checks passed")
  }
}
