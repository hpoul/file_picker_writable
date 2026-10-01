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
    prefix + root + ":" + encode(path)
  }

  /// The part every child of one listing shares: everything up to the
  /// child's own (encoded) name. `listChildren` sends it once per listing
  /// instead of once per entry (the root bookmark is ~2.5 KB; 10k
  /// children would repeat it 25.8 MB), and Dart appends each entry's
  /// `encode(name)`. Percent-encoding is per character, so
  /// `listingPrefix(root, parent) + encode(name)` is exactly
  /// `make(root, join(parent, name))`.
  static func listingPrefix(root: String, parentPath: String) -> String {
    prefix + root + ":" + (parentPath.isEmpty ? "" : encode(parentPath) + "/")
  }

  static func encode(_ path: String) -> String {
    path.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path
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
    identifier(withRoot: try currentRoot())
  }

  /// This identifier over `root`, for callers that already minted
  /// `currentRoot()` (a stale root costs a bookmark each time).
  func identifier(withRoot root: String) -> String {
    relativePath.isEmpty ? root : ChildIdentifier.make(root: root, path: relativePath)
  }

  /// The entry `name` directly below this one, under the same root and
  /// scope. `name` must satisfy the leaf-name rule.
  func child(_ name: String) -> ResolvedIdentifier {
    ResolvedIdentifier(
      url: url.appendingPathComponent(name),
      scopeURL: scopeURL,
      isStale: isStale,
      rootBookmark: rootBookmark,
      relativePath: ChildIdentifier.join(relativePath, name)
    )
  }

  /// False when following symlinks takes `url` out of the root. Call with
  /// the root's scope held; the sandbox would refuse such an escape on a
  /// device, but the simulator does not enforce it, so the plugin does.
  var isContained: Bool {
    if relativePath.isEmpty {
      return true
    }
    guard let root = Self.resolvedPath(scopeURL), let child = Self.resolvedPath(url), root != "/" else {
      // A loop on either side, or a root that is the file system root:
      // never contained.
      return false
    }
    // Strictly below the root: a child path that resolves to the root
    // itself (e.g. `selfrel -> ../root`) is refused, although the kernel
    // would reach the root. Deliberately conservative; a caller wanting
    // the root uses the root's own identifier.
    return child.hasPrefix(root + "/")
  }

  /// The path the kernel reaches for `url`, or nil when that cannot be
  /// determined (a symlink loop).
  ///
  /// Resolved component by component, the way the kernel walks a path:
  /// `..` only ever pops a prefix that is already resolved and holds no
  /// symlinks, and every symlink met (existing target or dangling, final
  /// or in the middle) is replaced by its target, relative to the
  /// resolved directory it sits in. Textual helpers get both wrong:
  /// `resolvingSymlinksInPath` leaves a not-yet-existing or dangling path
  /// alone, and `standardizedFileURL` collapses `..` against components
  /// that may themselves be symlinks (#69 review F1). Components that do
  /// not exist are taken literally, as a create would name them.
  ///
  /// The symlink-free invariant assumes `destinationOfSymbolicLink` fails
  /// only for "not a symlink". If it fails otherwise (EACCES — reachable
  /// only once the walk has already left the root), the link is appended
  /// literally and a later `..` pops it as text; every such case resolves
  /// to a path the root does not contain, so the error is a false refusal,
  /// never a false "contained".
  static func resolvedPath(_ url: URL) -> String? {
    let fm = FileManager.default
    var resolved: [String] = []
    var pending = ChildIdentifier.components(of: url.path).filter { !$0.isEmpty }
    var hops = 0
    while !pending.isEmpty {
      let part = pending.removeFirst()
      if part == "." {
        continue
      }
      if part == ".." {
        if !resolved.isEmpty {
          resolved.removeLast()
        }
        continue
      }
      let candidate = "/" + (resolved + [part]).joined(separator: "/")
      if let destination = try? fm.destinationOfSymbolicLink(atPath: candidate) {
        hops += 1
        guard hops <= 40 else {
          return nil
        }
        if destination.hasPrefix("/") {
          resolved = []
        }
        pending = ChildIdentifier.components(of: destination).filter { !$0.isEmpty } + pending
        continue
      }
      resolved.append(part)
    }
    return "/" + resolved.joined(separator: "/")
  }
}
