import Foundation

/// The file-system half of `deleteEntry` and `moveEntry`
/// (doc/tree-writes-plan.md §5): the recursive delete's walk, and the
/// checks that a mutated entry is strictly inside its picked root.
///
/// Foundation-only on purpose: `ios/test/TreeWalkTests.swift` pins the
/// symlink behavior on the host (`tool/swift_unit_tests.sh`).
enum TreeWalk {
  static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
  }

  /// A directory itself, not a symlink to one (resource values do not
  /// follow the final link, but say so explicitly).
  static func isRealDirectory(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  /// Depth-first: every child before its directory. A symlink is removed
  /// as a link and never followed, so nothing outside the walked tree is
  /// ever listed or deleted.
  static func deleteChildren(_ children: [URL]) throws {
    for child in children {
      if try isRealDirectory(child) {
        let grandchildren = try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: [])
        try deleteChildren(grandchildren)
      }
      try removeIfPresent(child)
    }
  }

  /// `removeItem`, where something already gone is success.
  static func removeIfPresent(_ url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
      return
    }
  }

  /// The kernel's own path for `url` (`realpath(3)`), nil when it cannot
  /// be resolved (a missing or dangling target).
  static func realPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else {
      return nil
    }
    defer {
      free(resolved)
    }
    return String(cString: resolved)
  }

  /// Where the entry `url` itself sits, by the kernel: its own real path,
  /// or for a symlink the real path of its directory plus its name (the
  /// link is what a delete or move acts on, not its target).
  static func realEntryPath(_ url: URL) -> String? {
    if isSymlink(url) {
      return realPath(url.deletingLastPathComponent()).map { $0 + "/" + url.lastPathComponent }
    }
    return realPath(url)
  }

  /// True when some component of `relativePath` is one FAT would strip to
  /// nothing (trailing dots and spaces: `.. `, `. .`, `...`), so that it
  /// could name `..` or `.` on such a volume. Mirrors Android's
  /// `StorageVolumes.isStrictlyBelow`.
  static func hasStrippableComponent(_ relativePath: String) -> Bool {
    ChildIdentifier.components(of: relativePath).contains { component in
      component.unicodeScalars.reversed().drop(while: { $0 == "." || $0 == " " }).isEmpty
    }
  }
}
