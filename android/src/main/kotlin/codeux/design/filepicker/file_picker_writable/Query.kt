package codeux.design.filepicker.file_picker_writable

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
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
