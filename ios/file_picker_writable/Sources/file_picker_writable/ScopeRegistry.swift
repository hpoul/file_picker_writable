import Foundation

/// Error kinds shared by the experimental verbs (scope-registry-plan §6).
enum ErrorKind {
  static let permissionLost = "permission-lost"
  static let notFound = "not-found"
  static let scopeClosed = "scope-closed"
  static let notADirectory = "not-a-directory"
  static let notAFile = "not-a-file"
  static let alreadyExists = "already-exists"
  static let directoryNotEmpty = "directory-not-empty"
  static let unsupportedMove = "unsupported-move"
  static let rootProtected = "root-protected"
  static let invalidName = "invalid-name"
}

/// A failure that belongs to the taxonomy, raised as `kind`.
struct TaxonomyError: Error {
  let kind: String
  let message: String
  var underlying: Error? = nil
  /// Extra entries for the error's details map, e.g. a `reason`.
  var details: [String: Any] = [:]
}

/// Security-scope holds across Dart calls (doc/scope-registry-plan.md §5).
///
/// Apple scope is process-local and balanced: every successful
/// `startAccessingSecurityScopedResource` needs exactly one
/// `stopAccessingSecurityScopedResource`. So the registry refcounts per
/// file: the first token on a file starts access, the last one stops it.
/// Thread-safe: acquires run off main, concurrently.
final class ScopeRegistry {
  struct StartRefused: Error {}

  private struct Hold {
    /// The instance access was started on, so the stop balances it.
    let url: URL
    var tokens: Set<String>
  }

  private let lock = NSLock()
  private var session: String?
  /// Keyed by file path: two resolutions of one bookmark are two URL
  /// instances for the same file.
  private var holds: [String: Hold] = [:]
  private var tokenKeys: [String: String] = [:]
  /// What each token was acquired for: the held file, or a child of it,
  /// with the root and path its child identifiers are minted from.
  private var tokenTargets: [String: ResolvedIdentifier] = [:]

  /// Adds a token for `target`, held through the scope of `url` (the
  /// target itself, or the root it lives under), starting access if that
  /// file has no hold yet. A new `session` (a fresh Dart isolate, e.g.
  /// after a hot restart) first balances every hold of the old one, so
  /// those tokens fail loud rather than silently rebind. Throws
  /// `StartRefused` when the system refuses the scope. Returns the token
  /// and how many old tokens were dropped.
  func acquire(url: URL, target: ResolvedIdentifier, session: String) throws -> (token: String, dropped: Int) {
    lock.lock()
    defer { lock.unlock() }
    var dropped = 0
    if session != self.session {
      dropped = _releaseAll()
      self.session = session
    }
    let key = url.standardizedFileURL.path
    let token = UUID().uuidString
    if var hold = holds[key] {
      hold.tokens.insert(token)
      holds[key] = hold
    } else {
      guard url.startAccessingSecurityScopedResource() else {
        throw StartRefused()
      }
      holds[key] = Hold(url: url, tokens: [token])
    }
    tokenKeys[token] = key
    tokenTargets[token] = target
    return (token, dropped)
  }

  /// The target `token` was acquired for, or nil when the token is not
  /// live (released, from an old session, or never issued): the verbs
  /// that take a scope answer that with `scope-closed`.
  func target(of token: String) -> ResolvedIdentifier? {
    lock.lock()
    defer { lock.unlock() }
    return tokenTargets[token]
  }

  /// Drops `token`, stopping access with the file's last token. False if
  /// the token was unknown (released twice, or from an old session).
  @discardableResult
  func release(token: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let key = tokenKeys.removeValue(forKey: token) else {
      return false
    }
    tokenTargets[token] = nil
    guard var hold = holds[key] else {
      return true
    }
    hold.tokens.remove(token)
    if hold.tokens.isEmpty {
      hold.url.stopAccessingSecurityScopedResource()
      holds[key] = nil
    } else {
      holds[key] = hold
    }
    return true
  }

  /// Balances every started scope and forgets every token: engine
  /// teardown, where Dart-side `release` never runs.
  @discardableResult
  func releaseAll() -> Int {
    lock.lock()
    defer { lock.unlock() }
    session = nil
    return _releaseAll()
  }

  /// Files currently held and live tokens, for leak debugging.
  var counts: (files: Int, tokens: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (holds.count, tokenKeys.count)
  }

  private func _releaseAll() -> Int {
    let dropped = tokenKeys.count
    for hold in holds.values {
      hold.url.stopAccessingSecurityScopedResource()
    }
    holds = [:]
    tokenKeys = [:]
    tokenTargets = [:]
    return dropped
  }
}
