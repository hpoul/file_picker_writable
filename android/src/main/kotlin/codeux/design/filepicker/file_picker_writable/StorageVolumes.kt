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

  /**
   * True only when [documentId] names an entry strictly inside the tree
   * [treeId]: the tree's own ID, its separator, then one or more leaf
   * names. The provider resolves IDs through the file system, so other
   * spellings may still name the root itself (`primary:Trips/`,
   * `primary:Trips/.`, `primary:trips` on case-insensitive storage), and
   * a recursive delete of one of those would empty the whole pick. So
   * anything not in exactly this shape is "not below the root".
   */
  fun isStrictlyBelow(treeId: String, documentId: String): Boolean {
    val prefix = if (treeId.endsWith(':')) treeId else "$treeId/"
    if (!documentId.startsWith(prefix) || documentId.length == prefix.length) {
      return false
    }
    return documentId.substring(prefix.length).split('/').all(::isLeafName)
  }

  /**
   * The inverse of [childDocumentId]: the document ID of the directory
   * [documentId] sits in, or null for a volume root (`primary:`) or an ID
   * without a root tag.
   */
  fun parentDocumentId(documentId: String): String? {
    val colon = documentId.indexOf(':')
    if (colon < 0 || colon == documentId.length - 1) {
      return null
    }
    val slash = documentId.lastIndexOf('/')
    return if (slash < colon) documentId.substring(0, colon + 1) else documentId.substring(0, slash)
  }

  sealed class Volume {
    object Primary : Volume()
    data class Uuid(val uuid: String) : Volume()
  }
}
