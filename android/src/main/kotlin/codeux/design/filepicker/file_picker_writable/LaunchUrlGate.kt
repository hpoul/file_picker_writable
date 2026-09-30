package codeux.design.filepicker.file_picker_writable

/**
 * Holds launch URLs until Dart calls `init`, then hands each over exactly
 * once.
 *
 * Main-thread confined, and checked: `init` hops to main like the picker
 * verbs, `onNewIntent` arrives on main, and [requireConfined] rejects any
 * other caller. Neither method suspends between its check and its update,
 * so an intent can never land between `init` reading the queue and
 * clearing it: no URL is dropped or handled twice.
 */
class LaunchUrlGate<T>(private val requireConfined: () -> Unit) {
  private var isOpen = false
  private val pending = mutableListOf<T>()

  /** True if [url] should be handled now; otherwise it waits for [open]. */
  fun offer(url: T): Boolean {
    requireConfined()
    if (isOpen) {
      return true
    }
    pending += url
    return false
  }

  /**
   * Opens the gate and returns the waiting URLs, oldest first. A second
   * call (e.g. `init` after a hot restart) returns nothing.
   */
  fun open(): List<T> {
    requireConfined()
    isOpen = true
    return pending.toList().also { pending.clear() }
  }
}
