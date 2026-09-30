package codeux.design.filepicker.file_picker_writable

import java.util.UUID

/**
 * Live `acquire` tokens (doc/scope-registry-plan.md §5). Android holds no
 * native resource per scope, so this only tracks which tokens are live:
 * release bookkeeping now, and the `scope-closed` check for the verbs that
 * take a scope once they land.
 *
 * Thread-safe: acquire and release run on the concurrent TaskQueue.
 */
class ScopeTokens {
  private var session: String? = null
  private val tokens = mutableMapOf<String, String>()

  /**
   * Adds a token for [identifier]. A new [session] (a fresh Dart isolate,
   * e.g. after a hot restart) first drops every token of the old one, so
   * those fail loud rather than silently rebind. Returns the new token and
   * how many old tokens were dropped.
   */
  @Synchronized
  fun add(session: String, identifier: String): Pair<String, Int> {
    var dropped = 0
    if (session != this.session) {
      dropped = tokens.size
      tokens.clear()
      this.session = session
    }
    val token = UUID.randomUUID().toString()
    tokens[token] = identifier
    return token to dropped
  }

  /** Drops [token]. False if it was unknown (released twice, or stale). */
  @Synchronized
  fun release(token: String): Boolean = tokens.remove(token) != null

  @get:Synchronized
  val size: Int
    get() = tokens.size

  @Synchronized
  fun clear() {
    tokens.clear()
    session = null
  }
}
