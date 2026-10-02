package codeux.design.filepicker.file_picker_writable

import java.io.FileNotFoundException

/**
 * `entryState`'s decision (scope-registry-plan §9) over injected
 * [Probes], so the order and the error mapping are pinned by unit tests
 * rather than by device runs alone. The first answer wins: the grant, the
 * volume (before the entry: a detached volume keeps its grant and its
 * documents read as missing), the entry's row, and a real open.
 *
 * A volume found absent by any probe (`volume-absent` from the volume
 * check) is [EntryState.VOLUME_ABSENT], a `SecurityException` from any
 * probe is [EntryState.PERMISSION_LOST]. An open that fails is decided by
 * the row again: gone since the first look is [EntryState.NOT_FOUND],
 * anything else stays loud with the open's own exception, suppressed into
 * the recheck's when that one throws too.
 */
object EntryStateDecision {
  /** What the platform is asked, in the order the decision asks it. */
  interface Probes {
    /** A persisted read grant covers the identifier. */
    fun hasGrant(): Boolean

    /** The identifier's volume is known to the system and not mounted. */
    fun volumeAbsent(): Boolean

    /**
     * Whether the entry is a directory, or null when it is provably gone;
     * throws when that cannot be proven.
     */
    fun isDirectory(): Boolean?

    /**
     * Opens the entry, reads up to one byte and closes it again: false
     * when the provider opened nothing.
     */
    fun openAndRead(): Boolean
  }

  /** The answer for the entry [what] names (for loud messages only). */
  fun decide(what: String, probes: Probes): String {
    if (!probes.hasGrant()) {
      return EntryState.PERMISSION_LOST
    }
    if (probes.volumeAbsent()) {
      return EntryState.VOLUME_ABSENT
    }
    return try {
      probe(what, probes)
    } catch (e: TaxonomyException) {
      if (e.details["reason"] != "volume-absent") {
        throw e
      }
      EntryState.VOLUME_ABSENT
    } catch (e: SecurityException) {
      EntryState.PERMISSION_LOST
    }
  }

  private fun probe(what: String, probes: Probes): String {
    val isDirectory = probes.isDirectory() ?: return EntryState.NOT_FOUND
    if (isDirectory) {
      return EntryState.NOT_A_FILE
    }
    val failure: Exception = try {
      if (probes.openAndRead()) {
        return EntryState.READABLE
      }
      IllegalStateException("The provider opened no descriptor for $what, which exists")
    } catch (e: TaxonomyException) {
      throw e
    } catch (e: SecurityException) {
      throw e
    } catch (e: Exception) {
      // The error reply would read this one as `not-found`, which the row
      // has just disproved.
      if (e is FileNotFoundException) {
        IllegalStateException("$what exists but does not open: $e", e)
      } else {
        e
      }
    }
    val again = try {
      probes.isDirectory()
    } catch (recheck: Exception) {
      recheck.addSuppressed(failure)
      throw recheck
    }
    if (again == null) {
      return EntryState.NOT_FOUND
    }
    throw failure
  }
}
