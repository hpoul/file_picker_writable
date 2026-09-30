package codeux.design.filepicker.file_picker_writable

/**
 * Which storage volume an ExternalStorageProvider document lives on.
 *
 * AOSP's ExternalStorageProvider drops an unmounted volume's root, then
 * `DocumentsProvider.query` swallows the resulting `FileNotFoundException`
 * and returns null, while the persisted grant survives. So a detached stick
 * and a deleted folder look the same from a query. Its document IDs are
 * `<root>:<path>`, where the root is `primary` (or `home`, the primary
 * volume's Documents root) or the volume's fsUuid. That tag names the
 * volume to ask `StorageManager` about. Other providers are opaque, so
 * this only applies to [AUTHORITY].
 */
object StorageVolumes {
  const val AUTHORITY = "com.android.externalstorage.documents"

  /** The volume a document ID lives on, or null if the ID has no tag. */
  fun volumeOf(documentId: String): Volume? {
    val tag = documentId.substringBefore(':', missingDelimiterValue = "")
    return when {
      tag.isEmpty() -> null
      tag == "primary" || tag == "home" -> Volume.Primary
      else -> Volume.Uuid(tag)
    }
  }

  /**
   * The document ID of [name] directly under [parentId]: `<root>:<path>`,
   * where a volume root's own ID ends in `:` and deeper levels join with
   * `/`. [name] must already satisfy the leaf-name rule.
   */
  fun childDocumentId(parentId: String, name: String): String =
    if (parentId.endsWith(':')) "$parentId$name" else "$parentId/$name"

  sealed class Volume {
    object Primary : Volume()
    data class Uuid(val uuid: String) : Volume()
  }
}
