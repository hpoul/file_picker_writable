package codeux.design.filepicker.file_picker_writable

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.FileNotFoundException
import java.io.IOException

class EntryStateDecisionTest {
  /**
   * Probes answering from fields; the row answers in turn ([rows]), so a
   * recheck after a failed open can see something else. [asked] records
   * the order.
   */
  private class Fake(
    val grant: Boolean = true,
    val absent: Boolean = false,
    val rows: List<() -> Boolean?> = listOf({ false }),
    val open: () -> Int? = { 0x42 }
  ) : EntryStateDecision.Probes {
    val asked = mutableListOf<String>()
    private var row = 0

    override fun hasGrant(): Boolean {
      asked += "grant"
      return grant
    }

    override fun volumeAbsent(): Boolean {
      asked += "volume"
      return absent
    }

    override fun isDirectory(): Boolean? {
      asked += "row"
      return rows[minOf(row++, rows.size - 1)]()
    }

    override fun openAndRead(): Int? {
      asked += "open"
      return open()
    }
  }

  private fun decide(fake: Fake) = EntryStateDecision.decide("doc", fake)

  private fun volumeAbsent() = TaxonomyException(
    ErrorKind.PERMISSION_LOST,
    "not mounted",
    details = mapOf("reason" to "volume-absent")
  )

  private inline fun <reified T : Throwable> loud(fake: Fake): T {
    try {
      fail("answered ${decide(fake)}")
    } catch (e: Throwable) {
      if (e !is T) {
        throw e
      }
      return e
    }
    throw AssertionError("unreachable")
  }

  @Test
  fun aFileThatOpensAndReadsIsReadable() {
    val fake = Fake()
    assertEquals(EntryState.READABLE, decide(fake))
    assertEquals(listOf("grant", "volume", "row", "open"), fake.asked)
  }

  @Test
  fun anEmptyFileReadsToEndOfFileAndIsReadable() {
    assertEquals(EntryState.READABLE, decide(Fake(open = { -1 })))
  }

  @Test
  fun theGrantAnswersFirst() {
    // A released grant on an absent volume is lost: picking again is the
    // only way back, whatever the volume does.
    val fake = Fake(grant = false, absent = true)
    assertEquals(EntryState.PERMISSION_LOST, decide(fake))
    assertEquals(listOf("grant"), fake.asked)
  }

  @Test
  fun theVolumeAnswersBeforeTheEntry() {
    // A detached volume keeps its grant, and its documents look missing.
    val fake = Fake(absent = true, rows = listOf({ null }))
    assertEquals(EntryState.VOLUME_ABSENT, decide(fake))
    assertEquals(listOf("grant", "volume"), fake.asked)
  }

  @Test
  fun aProvablyGoneEntryIsNotFound() {
    val fake = Fake(rows = listOf({ null }))
    assertEquals(EntryState.NOT_FOUND, decide(fake))
    assertEquals(listOf("grant", "volume", "row"), fake.asked)
  }

  @Test
  fun aDirectoryIsNotAFileAndIsNeverOpened() {
    val fake = Fake(rows = listOf({ true }))
    assertEquals(EntryState.NOT_A_FILE, decide(fake))
    assertEquals(listOf("grant", "volume", "row"), fake.asked)
  }

  @Test
  fun theVolumeGoingAwayDuringAProbeIsVolumeAbsent() {
    assertEquals(EntryState.VOLUME_ABSENT, decide(Fake(rows = listOf({ throw volumeAbsent() }))))
    assertEquals(EntryState.VOLUME_ABSENT, decide(Fake(open = { throw volumeAbsent() })))
  }

  @Test
  fun aSecurityExceptionIsPermissionLost() {
    assertEquals(EntryState.PERMISSION_LOST, decide(Fake(rows = listOf({ throw SecurityException() }))))
    val refused = Fake(open = { throw SecurityException("refused") })
    assertEquals(EntryState.PERMISSION_LOST, decide(refused))
    // Refused is an answer: the row is not asked again.
    assertEquals(listOf("grant", "volume", "row", "open"), refused.asked)
  }

  @Test
  fun anOpenThatFailsOnAnEntryGoneSinceIsNotFound() {
    val fake = Fake(rows = listOf({ false }, { null }), open = { throw IOException("EIO") })
    assertEquals(EntryState.NOT_FOUND, decide(fake))
    assertEquals(listOf("grant", "volume", "row", "open", "row"), fake.asked)
    val nothing = Fake(rows = listOf({ false }, { null }), open = { null })
    assertEquals(EntryState.NOT_FOUND, decide(nothing))
  }

  @Test
  fun aReadThatFailsOnAnEntryStillThereIsLoudWithItsOwnException() {
    val eio = IOException("EIO")
    val e = loud<IOException>(Fake(open = { throw eio }))
    assertSame(eio, e)
  }

  @Test
  fun aFileNotFoundExceptionWithALiveRowIsLoudNotNotFound() {
    val fnfe = FileNotFoundException("no such file")
    val e = loud<IllegalStateException>(Fake(open = { throw fnfe }))
    assertSame(fnfe, e.cause)
  }

  @Test
  fun noDescriptorForALiveRowIsLoud() {
    val e = loud<IllegalStateException>(Fake(open = { null }))
    assertTrue(e.message!!.contains("doc"))
  }

  @Test
  fun anUnprovableRecheckKeepsTheOpensExceptionSuppressed() {
    val eio = IOException("EIO")
    val unprovable = IllegalStateException("Cannot tell whether doc is gone")
    val e = loud<IllegalStateException>(
      Fake(rows = listOf({ false }, { throw unprovable }), open = { throw eio })
    )
    assertSame(unprovable, e)
    assertSame(eio, e.suppressed.single())
  }

  @Test
  fun otherTaxonomyKindsStayLoud() {
    val other = TaxonomyException(ErrorKind.NOT_FOUND, "other")
    assertSame(other, loud<TaxonomyException>(Fake(rows = listOf({ throw other }))))
  }
}
