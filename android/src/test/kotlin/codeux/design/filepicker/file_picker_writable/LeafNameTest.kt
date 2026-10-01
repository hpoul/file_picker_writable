package codeux.design.filepicker.file_picker_writable

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LeafNameTest {

  @Test
  fun ordinaryNamesAndDotfilesPass() {
    for (name in listOf("trip.json", ".howitwent", ".prev", "trip.json.writing", "12:30 ride.mp4", "...")) {
      assertTrue(name, isLeafName(name))
    }
  }

  @Test
  fun pathsAndSpecialNamesFail() {
    for (name in listOf("", ".", "..", "a/b", "/", "../x", "a\u0000b")) {
      assertFalse(name, isLeafName(name))
    }
  }

  @Test
  fun childIdsJoinUnderAVolumeRootAndBelowIt() {
    assertEquals("primary:Trips", StorageVolumes.childDocumentId("primary:", "Trips"))
    assertEquals("primary:Trips/.howitwent", StorageVolumes.childDocumentId("primary:Trips", ".howitwent"))
    assertEquals(
      "3C61-1EFF:FpwStick/2026/trip.json",
      StorageVolumes.childDocumentId("3C61-1EFF:FpwStick/2026", "trip.json")
    )
  }

  @Test
  fun parentIdsInvertChildIds() {
    for ((parent, name) in listOf(
      "primary:" to "Trips",
      "primary:Trips" to ".howitwent",
      "3C61-1EFF:FpwStick/2026" to "trip.json"
    )) {
      val child = StorageVolumes.childDocumentId(parent, name)
      assertEquals(parent, StorageVolumes.parentDocumentId(child))
    }
  }

  @Test
  fun aVolumeRootOrUntaggedIdHasNoParent() {
    assertEquals(null, StorageVolumes.parentDocumentId("primary:"))
    assertEquals(null, StorageVolumes.parentDocumentId("3C61-1EFF:"))
    assertEquals(null, StorageVolumes.parentDocumentId("opaque-id"))
  }
}
