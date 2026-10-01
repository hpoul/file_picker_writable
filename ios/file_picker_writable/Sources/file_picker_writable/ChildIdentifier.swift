import Foundation

/// Identifiers for children found by `listChildren`/`lookupChild`: the
/// picked root's bookmark plus a relative path, never a bookmark per child.
///
/// Minting a bookmark costs about 4.7 ms per child (10k children: 47 s of
/// a 48 s listing, iOS simulator), and a child bookmark's own security
/// scope is unproven on device. A root bookmark plus a path costs nothing
/// per child, and the child's access comes from the root's scope, which is
/// the scope the user granted. Like Android's path-based document IDs, a
/// child identifier follows a rename only through its root.
///
/// Foundation-only on purpose: `ios/test/ChildIdentifierTests.swift` pins
/// the traversal boundary on the host (`tool/swift_unit_tests.sh`).
enum ChildIdentifier {
  static let prefix = "fpwchild1:"

  struct Malformed: Error, CustomStringConvertible {
    let description: String
  }

  /// Allowed unescaped in the path part: path characters minus `%`.
  private static let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%"))

  static func make(root: String, path: String) -> String {
    prefix + root + ":" + (path.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path)
  }

  /// The root bookmark and relative path of a child identifier, nil for an
  /// identifier without the prefix (a plain bookmark). Base64 never
  /// contains `:`, so the first `:` after the prefix ends the root; the
  /// path may contain `:`. Every component must satisfy the leaf-name
  /// rule, so a decoded identifier never leaves its root by its path
  /// (`%2F` decodes to a separator; `.`, `..`, empty, `/`-led or NUL
  /// components are rejected).
  static func parse(_ identifier: String) throws -> (root: String, path: String)? {
    guard identifier.hasPrefix(prefix) else {
      return nil
    }
    let rest = identifier.dropFirst(prefix.count)
    guard let separator = rest.firstIndex(of: ":") else {
      throw Malformed(description: "Child identifier has no path.")
    }
    let root = String(rest[..<separator])
    guard !root.isEmpty, Data(base64Encoded: root) != nil else {
      throw Malformed(description: "Child identifier has no valid root bookmark.")
    }
    guard let path = String(rest[rest.index(after: separator)...]).removingPercentEncoding else {
      throw Malformed(description: "Child identifier path is not valid percent-encoding.")
    }
    guard components(of: path).allSatisfy(isLeafName) else {
      throw Malformed(description: "Child identifier path leaves its root or has an invalid component.")
    }
    return (root, path)
  }

  /// Path components split on the `/` scalar. Splitting on scalars, not
  /// graphemes, keeps a combining mark after `/` from hiding the separator.
  static func components(of path: String) -> [String] {
    path.unicodeScalars
      .split(separator: "/", omittingEmptySubsequences: false)
      .map { String(String.UnicodeScalarView($0)) }
  }

  /// The leaf-name rule (tree-writes-plan §4), checked on scalars.
  static func isLeafName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".."
      && !name.unicodeScalars.contains("/") && !name.unicodeScalars.contains("\u{0}")
  }

  static func join(_ path: String, _ name: String) -> String {
    path.isEmpty ? name : path + "/" + name
  }
}

/// An identifier resolved to the URL it names and the URL whose security
/// scope covers it (the same URL for a plain bookmark).
struct ResolvedIdentifier {
  let url: URL
  let scopeURL: URL
  let isStale: Bool
  let rootBookmark: String
  let relativePath: String

  /// The root bookmark to hand out: fresh when the given one was stale.
  func currentRoot() throws -> String {
    isStale ? try scopeURL.bookmarkData().base64EncodedString() : rootBookmark
  }

  /// This identifier as the caller should now persist it.
  func currentIdentifier() throws -> String {
    let root = try currentRoot()
    return relativePath.isEmpty ? root : ChildIdentifier.make(root: root, path: relativePath)
  }

  /// False when following symlinks takes `url` out of the root. Call with
  /// the root's scope held; the sandbox would refuse such an escape on a
  /// device, but the simulator does not enforce it, so the plugin does.
  var isContained: Bool {
    if relativePath.isEmpty {
      return true
    }
    let root = Self.resolvedPath(scopeURL)
    return Self.resolvedPath(url).hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  /// `url` with every symlink resolved, including on a path that does not
  /// exist yet: `resolvingSymlinksInPath` leaves such a path alone, so a
  /// new file through a symlinked directory would look contained. Resolve
  /// the deepest existing ancestor (checked without following its final
  /// link) and append the rest.
  static func resolvedPath(_ url: URL) -> String {
    var existing = url.standardizedFileURL
    var tail: [String] = []
    while (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil,
          existing.pathComponents.count > 1 {
      tail.insert(existing.lastPathComponent, at: 0)
      existing = existing.deletingLastPathComponent()
    }
    return tail.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
  }
}
