package codeux.design.filepicker.file_picker_writable

import codeux.design.filepicker.file_picker_writable.StorageVolumes.Volume
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StorageVolumesTest {

  @Test
  fun primaryAndHomeNameThePrimaryVolume() {
    assertEquals(Volume.Primary, StorageVolumes.volumeOf("primary:Trips"))
    assertEquals(Volume.Primary, StorageVolumes.volumeOf("primary:"))
    assertEquals(Volume.Primary, StorageVolumes.volumeOf("home:Trips"))
  }

  @Test
  fun aRemovableVolumeIsNamedByItsFsUuid() {
    assertEquals(Volume.Uuid("1A2B-3C4D"), StorageVolumes.volumeOf("1A2B-3C4D:Trips/2026"))
  }

  @Test
  fun onlyTheFirstColonSplits() {
    assertEquals(Volume.Uuid("1A2B-3C4D"), StorageVolumes.volumeOf("1A2B-3C4D:a:b"))
  }

  @Test
  fun anIdWithoutATagNamesNoVolume() {
    assertNull(StorageVolumes.volumeOf("Trips"))
    assertNull(StorageVolumes.volumeOf(":Trips"))
    assertNull(StorageVolumes.volumeOf(""))
  }
}
