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
enum ChildIdentifier {
  static let prefix = "fpwchild1:"

  /// Allowed unescaped in the path part: path characters minus `%`.
  private static let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%"))

  static func make(root: String, path: String) -> String {
    prefix + root + ":" + (path.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path)
  }

  /// The root bookmark and relative path of a child identifier, nil for a
  /// plain bookmark identifier. Base64 never contains `:`, so the first
  /// `:` after the prefix ends the root; the path may contain `:`.
  static func parse(_ identifier: String) throws -> (root: String, path: String)? {
    guard identifier.hasPrefix(prefix) else {
      return nil
    }
    let rest = identifier.dropFirst(prefix.count)
    guard
      let separator = rest.firstIndex(of: ":"),
      let path = String(rest[rest.index(after: separator)...]).removingPercentEncoding
    else {
      throw FilePickerError.invalidArguments(message: "Malformed child identifier.")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw FilePickerError.invalidArguments(message: "Malformed child identifier path.")
    }
    return (String(rest[..<separator]), path)
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
}
