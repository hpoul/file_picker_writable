package codeux.design.filepicker.file_picker_writable

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.annotation.RequiresApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Get the display name for [uri].
 *
 * - Expects: {Tree+}document URI
 */
suspend fun getDisplayName(
  uri: Uri,
  contentResolver: ContentResolver
): String = withContext(Dispatchers.IO) {
  // The query, because it only applies to a single document, returns only
  // one row. There's no need to filter, sort, or select fields,
  // because we want all fields for one document.
  val cursor: Cursor? = contentResolver.query(
    uri, null, null, null, null, null
  )

  cursor?.use {
    if (!it.moveToFirst()) {
      throw FilePickerException("Cursor returned empty while trying to read file info for $uri")
    }

    // Note it's called "Display Name". This is
    // provider-specific, and might not necessarily be the file name.
    val displayName: String =
      it.getString(it.getColumnIndex(OpenableColumns.DISPLAY_NAME))
    displayName

  } ?: throw FilePickerException("Unable to load file info from $uri")
}

/**
 * Determine whether [uri] is a directory.
 *
 * - Expects: {Tree+}document URI
 */
suspend fun isDirectory(
  uri: Uri,
  contentResolver: ContentResolver
): Boolean = withContext(Dispatchers.IO) {
  // Like DocumentsContractApi19#isDirectory
  contentResolver.query(
    uri, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null, null
  )?.use {
    if (!it.moveToFirst()) {
      throw FilePickerException("Cursor returned empty while trying to read info for $uri")
    }
    val typeColumn = it.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
    val childType = it.getString(typeColumn)
    DocumentsContract.Document.MIME_TYPE_DIR == childType
  } ?: throw FilePickerException("Unable to query info for $uri")
}


/**
 * Directly compute the URI of the parent directory of the supplied child URI.
 * Efficient, but only available on Android O or later.
 *
 * - Expects: Tree{+document} URI
 * - Returns: Tree{+document} URI
 */
@RequiresApi(Build.VERSION_CODES.O)
suspend fun getParent(
  child: Uri,
  context: Context
): Uri? = withContext(Dispatchers.IO) {
  val uri = when {
    DocumentsContract.isDocumentUri(context, child) -> {
      // Tree+document URI (probably from getDirectory)
      child
    }
    DocumentsContract.isTreeUri(child) -> {
      // Just a tree URI (probably from pickDirectory)
      DocumentsContract.buildDocumentUriUsingTree(child, DocumentsContract.getTreeDocumentId(child))
    }
    else -> {
      throw Exception("Unknown URI type")
    }
  }
  val path = DocumentsContract.findDocumentPath(context.contentResolver, uri)
    ?: return@withContext null
  val parents = path.path
  if (parents.size < 2) {
    return@withContext null
  }
  // Last item is the child itself, so get second-to-last item
  val parent = parents[parents.lastIndex - 1]
  when {
    DocumentsContract.isTreeUri(child) -> {
      DocumentsContract.buildDocumentUriUsingTree(child, parent)
    }
    else -> {
      DocumentsContract.buildTreeDocumentUri(child.authority, parent)
    }
  }
}

/**
 * Starting at [root], perform a breadth-wise search through all children to
 * locate the immediate parent of [leaf].
 *
 * This is extremely inefficient compared to [getParent], but it is available on
 * older systems.
 *
 * - Expects: [root] is Tree{+document} URI; [leaf] is {tree+}document URI
 * - Returns: Tree+document URI
 */
@RequiresApi(Build.VERSION_CODES.LOLLIPOP)
suspend fun findParent(
  root: Uri,
  leaf: Uri,
  context: Context
): Uri? {
  val leafDocId = DocumentsContract.getDocumentId(leaf)
  val children = getChildren(root, context)
  // Do breadth-first search because hopefully the leaf is not too deep
  // relative to the root
  for (child in children) {
    if (DocumentsContract.getDocumentId(child) == leafDocId) {
      return root
    }
  }
  for (child in children) {
    if (isDirectory(child, context.contentResolver)) {
      val result = findParent(child, leaf, context)
      if (result != null) {
        return result
      }
    }
  }
  return null
}

/**
 * Return URIs of all children of [uri].
 *
 * - Expects: Tree{+document} or tree URI
 * - Returns: Tree+document URI
 */
@RequiresApi(Build.VERSION_CODES.LOLLIPOP)
suspend fun getChildren(
  uri: Uri,
  context: Context
): List<Uri> = withContext(Dispatchers.IO) {
  // Like TreeDocumentFile#listFiles
  val docId = when {
    DocumentsContract.isDocumentUri(context, uri) -> {
      DocumentsContract.getDocumentId(uri)
    }
    else -> {
      DocumentsContract.getTreeDocumentId(uri)
    }
  }
  val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, docId)
  context.contentResolver.query(
    childrenUri,
    arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null, null
  )?.use {
    val results = mutableListOf<Uri>()
    val idColumn = it.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
    while (it.moveToNext()) {
      val childDocId = it.getString(idColumn)
      val childUri = DocumentsContract.buildDocumentUriUsingTree(uri, childDocId)
      results.add(childUri)
    }
    results
  } ?: throw FilePickerException("Unable to query info for $uri")
}

/**
 * Check whether the file pointed to by [uri] exists.
 *
 * - Expects: {Tree+}document URI
 */
suspend fun fileExists(
  uri: Uri,
  contentResolver: ContentResolver
): Boolean = withContext(Dispatchers.IO) {
  // Like DocumentsContractApi19#exists
  contentResolver.query(
    uri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null, null
  )?.use {
    it.count > 0
  } ?: throw FilePickerException("Unable to query info for $uri")
}

/**
 * From the [start] point, compute the URI of the entity pointed to by
 * [relativePath].
 *
 * - Expects: Tree{+document} URI
 * - Returns: Tree{+document} URI
 */
@RequiresApi(Build.VERSION_CODES.LOLLIPOP)
suspend fun resolveRelativePath(
  start: Uri,
  relativePath: String,
  context: Context
): Uri? = withContext(Dispatchers.IO) {
  val stack = mutableListOf(start)
  for (segment in relativePath.split('/', '\\')) {
    when (segment) {
      "" -> {
      }
      "." -> {
      }
      ".." -> {
        val last = stack.removeAt(stack.lastIndex)
        if (stack.isEmpty()) {
          val parent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getParent(last, context)
          } else {
            null
          }
          if (parent != null) {
            stack.add(parent)
          } else {
            return@withContext null
          }
        }
      }
      else -> {
        val next = getChildByDisplayName(stack.last(), segment, context)
        if (next == null) {
          return@withContext null
        } else {
          stack.add(next)
        }
      }
    }
  }
  stack.last()
}

/**
 * Compute the URI of the named [child] under [parent].
 *
 * - Expects: Tree{+document} URI
 * - Returns: Tree+document URI
 */
@RequiresApi(Build.VERSION_CODES.LOLLIPOP)
suspend fun getChildByDisplayName(
  parent: Uri,
  child: String,
  context: Context
): Uri? = withContext(Dispatchers.IO) {
  val parentDocumentId = when {
    DocumentsContract.isDocumentUri(context, parent) -> {
      // Tree+document URI (probably from getDirectory)
      DocumentsContract.getDocumentId(parent)
    }
    else -> {
      // Just a tree URI (probably from pickDirectory)
      DocumentsContract.getTreeDocumentId(parent)
    }
  }
  val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parent, parentDocumentId)
  context.contentResolver.query(
    childrenUri,
    arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
    "${DocumentsContract.Document.COLUMN_DISPLAY_NAME} = ?",
    arrayOf(child),
    null
  )?.use {
    val idColumn = it.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
    val nameColumn = it.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
    var documentId: String? = null
    while (it.moveToNext()) {
      val name = it.getString(nameColumn)
      // FileSystemProvider doesn't respect our selection so we have to
      // manually filter here to be safe
      if (name == child) {
        documentId = it.getString(idColumn)
        break
      }
    }

    if (documentId != null) {
      DocumentsContract.buildDocumentUriUsingTree(parent, documentId)
    } else {
      null
    }
  }
}
