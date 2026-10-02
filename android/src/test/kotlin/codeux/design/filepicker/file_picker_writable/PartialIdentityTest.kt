package codeux.design.filepicker.file_picker_writable

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PartialIdentityTest {
  private val openedAt = 1_790_000_000_000L

  @Test
  fun theSessionsOwnPartialMatches() {
    assertTrue(PartialIdentity.matches(42, 42, 100, 100, openedAt + 5_000, openedAt))
    // FAT's 2-second mtime steps may round below the create.
    assertTrue(PartialIdentity.matches(42, 42, 100, 100, openedAt - 1_999, openedAt))
    // A provider that reports no size or time leaves the inode to decide.
    assertTrue(PartialIdentity.matches(42, 42, null, 100, null, openedAt))
  }

  @Test
  fun aNewcomerUnderTheNameNeverMatches() {
    // Another inode: a different file, whatever its size or age.
    assertFalse(PartialIdentity.matches(42, 43, 100, 100, openedAt + 5_000, openedAt))
    // The same inode reused after a delete, but other contents.
    assertFalse(PartialIdentity.matches(42, 42, 20, 100, openedAt + 5_000, openedAt))
    // The same inode, but older than the session: renamed into place.
    assertFalse(PartialIdentity.matches(42, 42, 100, 100, openedAt - 60_000, openedAt))
    // The boundary: just past FAT's 2-second slack.
    assertFalse(PartialIdentity.matches(42, 42, 100, 100, openedAt - 2_001, openedAt))
  }
}
