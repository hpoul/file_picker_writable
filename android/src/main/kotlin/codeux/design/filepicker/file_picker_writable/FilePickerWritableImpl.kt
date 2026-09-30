package codeux.design.filepicker.file_picker_writable

import android.app.Activity
import android.app.Activity.RESULT_OK
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Looper
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.DragEvent
import android.view.View
import androidx.annotation.MainThread
import androidx.annotation.WorkerThread
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

interface ContextProvider : CoroutineScope {
  val activity: Activity?

  val applicationContext: Context?

  fun logDebug(message: String, e: Throwable? = null)
  fun logWarning(message: String)
  @MainThread
  fun openFile(fileInfo: Map<String, String>)
  @MainThread
  fun handleOpenUri(uri: Uri)
  @MainThread
  fun handleDrop(files: List<Map<String, String>>)
  @MainThread
  fun dragEntered()
  @MainThread
  fun dragExited()
  @MainThread
  fun sendError(message: String)
}

class FilePickerWritableImpl(
  private val plugin: ContextProvider
) : PluginRegistry.ActivityResultListener, PluginRegistry.NewIntentListener {

  companion object {
    const val REQUEST_CODE_OPEN_FILE = 40832
    const val REQUEST_CODE_CREATE_FILE = 40833
    const val REQUEST_CODE_OPEN_DIRECTORY = 40834

    private val DOCUMENT_PROJECTION = arrayOf(
      DocumentsContract.Document.COLUMN_DOCUMENT_ID,
      DocumentsContract.Document.COLUMN_DISPLAY_NAME,
      DocumentsContract.Document.COLUMN_MIME_TYPE,
      DocumentsContract.Document.COLUMN_SIZE,
      DocumentsContract.Document.COLUMN_LAST_MODIFIED
    )
  }

  // Every mutable field below is touched on the main hop only, except the
  // thread-safe `scopes`: the control verbs run on a concurrent TaskQueue
  // and hop to main for any of this state.
  private var filePickerCreateFile: File? = null
  private var filePickerResult: MethodChannel.Result? = null

  private val launchUrls = LaunchUrlGate<Uri> {
    check(Looper.myLooper() == Looper.getMainLooper()) {
      "Launch URLs are main-thread confined."
    }
  }

  private val scopes = ScopeTokens()


  @MainThread
  fun openFilePicker(result: MethodChannel.Result) {
    if (filePickerResult != null) {
      throw FilePickerException("Invalid lifecycle, only one call at a time.")
    }
    filePickerResult = result
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      type = "*/*"
    }
    val activity = requireActivity()
    try {
      activity.startActivityForResult(intent, REQUEST_CODE_OPEN_FILE)
    } catch (e: ActivityNotFoundException) {
      filePickerResult = null
      plugin.logDebug("exception while launcing file picker", e)
      result.error(
        "FilePickerNotAvailable",
        "Unable to start file picker, $e",
        null
      )
    }
  }

  @MainThread
  fun openFilePickerForCreate(result: MethodChannel.Result, path: String) {
    if (filePickerResult != null) {
      throw FilePickerException("Invalid lifecycle, only one call at a time.")
    }
    val file = File(path)
    filePickerResult = result
    filePickerCreateFile = file
    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
//      type = "application/x-keepass"
      type = "*/*"
      putExtra(Intent.EXTRA_TITLE, file.name)
    }
    val activity = requireActivity()
    try {
      activity.startActivityForResult(intent, REQUEST_CODE_CREATE_FILE)
    } catch (e: ActivityNotFoundException) {
      filePickerResult = null
      plugin.logDebug("exception while launcing file picker", e)
      result.error(
        "FilePickerNotAvailable",
        "Unable to start file picker, $e",
        null
      )
    }
  }

  @MainThread
  fun openDirectory(result: MethodChannel.Result) {
    if (filePickerResult != null) {
      throw FilePickerException("Invalid lifecycle, only one call at a time.")
    }
    val activity = requireActivity()
    filePickerResult = result
    try {
      activity.startActivityForResult(
        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
        REQUEST_CODE_OPEN_DIRECTORY
      )
    } catch (e: ActivityNotFoundException) {
      filePickerResult = null
      plugin.logDebug("exception while launching directory picker", e)
      result.error(
        "FilePickerNotAvailable",
        "Unable to start directory picker, $e",
        null
      )
    }
  }

  override fun onActivityResult(
    requestCode: Int,
    resultCode: Int,
    data: Intent?
  ): Boolean {
    if (!arrayOf(
        REQUEST_CODE_OPEN_FILE,
        REQUEST_CODE_CREATE_FILE,
        REQUEST_CODE_OPEN_DIRECTORY
      ).contains(requestCode)) {
      plugin.logDebug("Unknown requestCode $requestCode - ignore")
      return false
    }

    val result = filePickerResult ?: return false.also {
      plugin.logDebug("We have no active result, so activity result was not for us.")
    }
    filePickerResult = null

    plugin.logDebug("onActivityResult($requestCode, $resultCode, ${data?.data})")

    if (resultCode == Activity.RESULT_CANCELED) {
      plugin.logDebug("Activity result was canceled.")
      result.success(null)
      return true
    } else if (resultCode != RESULT_OK) {
      result.error(
        "InvalidResult",
        "Got invalid result $resultCode",
        null
      )
      return true
    }
    if (requestCode == REQUEST_CODE_OPEN_DIRECTORY) {
      plugin.launch {
        try {
          val treeUri = data?.data
            ?: throw FilePickerException("RESULT_OK without a tree URI $data")
          plugin.logDebug("Got directory $treeUri")
          result.success(withContext(Dispatchers.IO) { takeDirectory(treeUri) })
        } catch (e: Exception) {
          plugin.logDebug("Error during handling directory picker result.", e)
          result.taxonomyError(e)
        }
      }
      return true
    }
    plugin.launch {
      try {
        when (requestCode) {
          REQUEST_CODE_OPEN_FILE -> {
            val fileUri = data?.data
            if (fileUri != null) {
              plugin.logDebug("Got result $fileUri")
              result.success(withContext(Dispatchers.IO) {
                copyContentUriAndReturnFileInfo(fileUri)
              })
            } else {
              plugin.logDebug("Got RESULT_OK with null fileUri?")
              result.success(null)
            }
          }
          REQUEST_CODE_CREATE_FILE -> {
            val initialFileContent = filePickerCreateFile
              ?: throw FilePickerException("illegal state - filePickerCreateFile was null")
            val fileUri =
              requireNotNull(data?.data) { "RESULT_OK with null file uri $data" }
            plugin.logDebug("Got result $fileUri")
            result.success(withContext(Dispatchers.IO) {
              takeCreatedFile(fileUri, initialFileContent)
            })
          }
          else -> {
            // can never happen, we already checked the result code.
            throw IllegalStateException("Unexpected requestCode $requestCode")
          }
        }
      } catch (e: Exception) {
        plugin.logDebug("Error during handling file picker result.", e)
        result.error(
          "FatalError",
          "Error handling file picker callback. $e",
          null
        )
      }
    }
    return true
  }

  @WorkerThread
  private fun takeCreatedFile(
    fileUri: Uri,
    initialFileContent: File
  ): Map<String, String> {
    val contentResolver = requireContext().contentResolver
    val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
      Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    contentResolver.takePersistableUriPermission(fileUri, takeFlags)

    return writeAndReturnFileInfo(fileUri, initialFileContent)
  }

  @WorkerThread
  fun readFileWithIdentifier(
    result: MethodChannel.Result,
    identifier: String
  ) {
    result.success(copyContentUriAndReturnFileInfo(Uri.parse(identifier)))
  }

  @WorkerThread
  private fun copyContentUriAndReturnFileInfo(
    fileUri: Uri,
    attemptPersistablePermission: Boolean = true,
    fileNameFallback: String? = null
  ): Map<String, String> {
    val context = requireContext()

    val contentResolver = context.contentResolver

    return run {
      var persistable = false
      if (attemptPersistablePermission) {
        try {
          val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
          contentResolver.takePersistableUriPermission(fileUri, takeFlags)
          persistable = true
        } catch (e: SecurityException) {
          plugin.logDebug("Couldn't take persistable URI permission on $fileUri", e)
        }
      }

      val fileName = if (fileNameFallback != null) {
        try {
          readFileInfo(fileUri, contentResolver)
        } catch (e: Exception) {
          plugin.logDebug("Couldn't read display name for $fileUri, using fallback.", e)
          fileNameFallback
        }
      } else {
        readFileInfo(fileUri, contentResolver)
      }

      // createTempFile requires a prefix of at least 3 characters; a
      // one- or two-character display name would throw here.
      val tempPrefix = fileName.take(20).padEnd(3, '_')
      val tempFile = File.createTempFile(tempPrefix, null, context.cacheDir)
      plugin.logDebug("Copy file $fileUri to $tempFile")
      try {
        contentResolver.openInputStream(fileUri).use { input ->
          requireNotNull(input)
          tempFile.outputStream().use { output ->
            input.copyTo(output)
          }
        }
      } catch (e: Exception) {
        // Don't orphan the temp file when the copy fails.
        tempFile.delete()
        throw e
      }
      mapOf(
        "path" to tempFile.absolutePath,
        "identifier" to fileUri.toString(),
        "persistable" to persistable.toString(),
        "fileName" to fileName,
        "uri" to fileUri.toString()
      )
    }
  }

  @WorkerThread
  private fun readFileInfo(
    uri: Uri,
    contentResolver: ContentResolver
  ): String = queryDisplayName(uri, contentResolver)
    ?: throw FilePickerException("Unable to load file info from $uri")

  /**
   * The display name of the document at [uri], or null when the provider
   * has no row for it: a missing document reads as a null cursor, since
   * `DocumentsProvider.query` swallows its `FileNotFoundException`.
   */
  @WorkerThread
  private fun queryDisplayName(
    uri: Uri,
    contentResolver: ContentResolver
  ): String? {
    // The query, because it only applies to a single document, returns only
    // one row. There's no need to filter, sort, or select fields,
    // because we want all fields for one document.
    val cursor: Cursor? = contentResolver.query(
      uri, null, null, null, null, null
    )

    return cursor?.use {
      if (!it.moveToFirst()) {
        return null
      }

      // Note it's called "Display Name". This is
      // provider-specific, and might not necessarily be the file name.
      val displayName: String =
        it.getString(it.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
      plugin.logDebug("Display Name: $displayName")
      displayName
    }
  }

  fun onDetachedFromActivity(binding: ActivityPluginBinding) {
    binding.removeActivityResultListener(this)
    detachDropIntake()
  }

  fun onAttachedToActivity(binding: ActivityPluginBinding) {
    binding.addActivityResultListener(this)
    binding.addOnNewIntentListener(this)
    attachDropIntake(binding.activity)
    onNewIntent(binding.activity.intent)
  }

  @WorkerThread
  fun writeFileWithIdentifier(
    result: MethodChannel.Result,
    identifier: String,
    file: File
  ) {
    result.success(writeAndReturnFileInfo(Uri.parse(identifier), file))
  }

  @WorkerThread
  private fun writeAndReturnFileInfo(
    fileUri: Uri,
    file: File
  ): Map<String, String> {
    if (!file.exists()) {
      throw FilePickerException("File at source not found. $file")
    }
    val contentResolver = requireContext().contentResolver
    // with Android 10 and later, use wt
    // https://issuetracker.google.com/issues/135714729?pli=1
    // https://github.com/hpoul/file_picker_writable/issues/23
    val writeMode = "wt".takeIf { Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q } ?: "w"
    contentResolver.openOutputStream(fileUri, writeMode).use { output ->
      require(output != null)
      file.inputStream().use { input ->
        input.copyTo(output)
      }
    }
    return copyContentUriAndReturnFileInfo(fileUri)
  }

  @WorkerThread
  fun disposeIdentifier(identifier: String) {
    val context = requireContext()
    val contentResolver = context.applicationContext.contentResolver
    val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
      Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    contentResolver.releasePersistableUriPermission(Uri.parse(identifier), takeFlags)
  }

  @WorkerThread
  fun disposeAllIdentifiers() {
    val context = requireContext()
    val contentResolver = context.applicationContext.contentResolver
    val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
      Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    for (permission in contentResolver.persistedUriPermissions) {
      plugin.logDebug("Releasing identifier: $permission")
      contentResolver.releasePersistableUriPermission(permission.uri, takeFlags)
    }
  }

  /**
   * Persists the grant on a picked tree and describes it. Acquisition
   * never touches a byte: no temp file, no copy.
   */
  @WorkerThread
  private fun takeDirectory(treeUri: Uri): Map<String, String> {
    val contentResolver = requireContext().contentResolver
    // Read+write where the provider grants it, read-only otherwise: a
    // read-only tree is still a successful pick, and `persistable` says
    // whether the grant outlives this process.
    val persistable = listOf(
      Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
      Intent.FLAG_GRANT_READ_URI_PERMISSION
    ).any { flags ->
      try {
        contentResolver.takePersistableUriPermission(treeUri, flags)
        true
      } catch (e: SecurityException) {
        plugin.logDebug("Couldn't persist tree grant (flags $flags) on $treeUri", e)
        false
      }
    }
    val name = queryDisplayName(documentUriFor(treeUri), contentResolver)
      ?: throw TaxonomyException(ErrorKind.NOT_FOUND, "No document for picked tree $treeUri")
    return mapOf(
      "identifier" to treeUri.toString(),
      "persistable" to persistable.toString(),
      "uri" to treeUri.toString(),
      "fileName" to name
    )
  }

  /**
   * Validates that a persisted grant still covers [identifier] and re-reads
   * its display name. Android holds nothing native per scope, so the token
   * is bookkeeping and the identifier is always echoed unrepaired.
   */
  @WorkerThread
  fun acquire(identifier: String, session: String): Map<String, Any?> {
    val uri = Uri.parse(identifier)
    val contentResolver = requireContext().contentResolver
    if (!hasPersistedReadGrant(contentResolver, uri)) {
      throw TaxonomyException(ErrorKind.PERMISSION_LOST, "No persisted grant covers $uri")
    }
    val documentUri = documentUriFor(uri)
    val name = onVolume(documentUri) { queryDisplayName(documentUri, contentResolver) }
      ?: throw missingDocument(documentUri)
    val (token, dropped) = scopes.add(session, identifier)
    if (dropped > 0) {
      // Expected once after a hot restart. Anything else means a second
      // isolate called acquire, which breaks the root-isolate rule and
      // just released the other isolate's holds.
      plugin.logWarning(
        "New Dart session: released $dropped scope token(s) of the previous one. " +
          "acquire is a root-isolate verb."
      )
    }
    plugin.logDebug("acquire: ${scopes.size} scope token(s) live.")
    return mapOf(
      "id" to token,
      "identifier" to identifier,
      "repaired" to false,
      "path" to null,
      "displayName" to name
    )
  }

  /** Drops a scope token. Unknown tokens are a logged no-op. */
  @WorkerThread
  fun release(token: String) {
    if (!scopes.release(token)) {
      plugin.logDebug("release: unknown scope token $token, ignored.")
    }
    plugin.logDebug("release: ${scopes.size} scope token(s) live.")
  }

  /**
   * One level of the directory [identifier] names, in one cursor pass:
   * metadata only, never a copy. Android identifiers never go stale, so
   * the identifier is echoed unrepaired.
   */
  @WorkerThread
  fun listChildren(identifier: String): Map<String, Any?> {
    val started = System.nanoTime()
    val directory = requireDirectory(identifier)
    val entries = requireChildren(directory)
    plugin.logDebug(
      "listChildren: ${entries.size} rows in ${(System.nanoTime() - started) / 1_000_000} ms"
    )
    return mapOf(
      "identifier" to identifier,
      "repaired" to false,
      "entries" to entries.map { it.toResult(directory.treeUri) }
    )
  }

  /**
   * The child [name] of the directory [identifier], or null when absent.
   * ExternalStorageProvider IDs are paths, so the child's ID is derived
   * and queried as one row; any other provider is opaque, so it falls back
   * to scanning the listing (same answer, listing cost; names match
   * exactly there, unlike ExternalStorageProvider's file system match).
   */
  @WorkerThread
  fun lookupChild(identifier: String, name: String): Map<String, Any?>? {
    if (!isLeafName(name)) {
      throw TaxonomyException(ErrorKind.INVALID_NAME, "Not a single leaf name: \"$name\"")
    }
    val directory = requireDirectory(identifier)
    val child = if (directory.treeUri.authority == StorageVolumes.AUTHORITY) {
      val childUri = DocumentsContract.buildDocumentUriUsingTree(
        directory.treeUri,
        StorageVolumes.childDocumentId(directory.documentId, name)
      )
      try {
        queryRow(childUri)
      } catch (e: IllegalArgumentException) {
        // The provider's tree check (isChildDocument) throws for a child it
        // cannot resolve — a missing file ("Failed to determine if … is
        // child of …", measured API 36), but also a canonicalize failure on
        // a failing stick, or a parent that vanished since requireDirectory.
        // So never decide on the exception: re-query the parent. Only a
        // parent that is still a live directory makes this the absent child.
        plugin.logDebug("lookupChild: child query threw ${e.message}; re-checking the parent")
        directoryRow(directory.documentUri, directory.isTreeRoot)
        null
      } ?: run {
        // A volume detached since requireDirectory reads as a null row.
        absentVolume(childUri)?.let { throw it }
        null
      }
    } else {
      requireChildren(directory).firstOrNull { it.name == name }
    }
    return child?.toResult(directory.treeUri)
  }

  private class Directory(
    val treeUri: Uri,
    val documentId: String,
    val documentUri: Uri,
    /** The picked tree's own root, whose tree check never runs. */
    val isTreeRoot: Boolean
  )

  private class DocumentRow(
    val documentId: String,
    val name: String,
    val mimeType: String?,
    val size: Long?,
    val lastModified: Long?
  ) {
    val isDirectory: Boolean
      get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR

    fun toResult(treeUri: Uri): Map<String, Any?> = mapOf(
      "name" to name,
      "identifier" to DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId).toString(),
      "isDirectory" to isDirectory,
      // A directory's size is the file system's block size, not content:
      // null, as on iOS.
      "size" to if (isDirectory) null else size,
      "lastModified" to lastModified
    )
  }

  /**
   * Resolves [identifier] to a directory under a live persisted tree grant:
   * `not-a-directory` unless it is a tree URI naming a directory,
   * `permission-lost` without a grant, and [missingDocument] when gone.
   */
  @WorkerThread
  private fun requireDirectory(identifier: String): Directory {
    val uri = Uri.parse(identifier)
    if (!DocumentsContract.isTreeUri(uri)) {
      throw TaxonomyException(ErrorKind.NOT_A_DIRECTORY, "Not a directory tree URI: $uri")
    }
    if (!hasPersistedReadGrant(requireContext().contentResolver, uri)) {
      throw TaxonomyException(ErrorKind.PERMISSION_LOST, "No persisted grant covers $uri")
    }
    val treeUri = DocumentsContract.buildTreeDocumentUri(
      uri.authority, DocumentsContract.getTreeDocumentId(uri)
    )
    val documentUri = documentUriFor(uri)
    val documentId = DocumentsContract.getDocumentId(documentUri)
    val isTreeRoot = documentId == DocumentsContract.getTreeDocumentId(uri)
    val row = directoryRow(documentUri, isTreeRoot)
    if (!row.isDirectory) {
      throw TaxonomyException(ErrorKind.NOT_A_DIRECTORY, "${row.name} is not a directory")
    }
    return Directory(treeUri, documentId, documentUri, isTreeRoot)
  }

  /**
   * The row of a directory that must still exist, else [missingDocument]
   * (`not-found`, or `volume-absent`). A gone tree root reads as a null
   * row, but anything below it goes through the provider's tree check,
   * which throws `IllegalArgumentException` for a missing file instead
   * (FileSystemProvider wraps the FileNotFoundException). So for a
   * non-root directory that exception means gone, never a raw error.
   */
  @WorkerThread
  private fun directoryRow(documentUri: Uri, isTreeRoot: Boolean): DocumentRow {
    val row = try {
      queryRow(documentUri)
    } catch (e: IllegalArgumentException) {
      if (isTreeRoot) {
        throw e
      }
      plugin.logDebug("Directory query threw ${e.message}; treating it as gone")
      null
    }
    return row ?: throw missingDocument(documentUri)
  }

  /**
   * All children of [directory], else [missingDocument]: a folder removed
   * since [requireDirectory] shows up here, as a null cursor or, below the
   * tree root, as the tree check's `IllegalArgumentException`.
   */
  @WorkerThread
  private fun requireChildren(directory: Directory): List<DocumentRow> {
    val children = try {
      queryChildren(directory)
    } catch (e: IllegalArgumentException) {
      if (directory.isTreeRoot) {
        throw e
      }
      plugin.logDebug("Children query threw ${e.message}; treating the directory as gone")
      null
    }
    return children ?: throw missingDocument(directory.documentUri)
  }

  /** The one row for [documentUri], or null when the provider has none. */
  @WorkerThread
  private fun queryRow(documentUri: Uri): DocumentRow? = onVolume(documentUri) {
    requireContext().contentResolver.query(documentUri, DOCUMENT_PROJECTION, null, null, null)
      ?.use { cursor -> if (cursor.moveToFirst()) cursor.toDocumentRow() else null }
  }

  /** All children of [directory] in one pass, or null for a null cursor. */
  @WorkerThread
  private fun queryChildren(directory: Directory): List<DocumentRow>? {
    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
      directory.treeUri, directory.documentId
    )
    return onVolume(directory.documentUri) {
      requireContext().contentResolver
        .query(childrenUri, DOCUMENT_PROJECTION, null, null, null)
        ?.use { cursor ->
          buildList {
            while (cursor.moveToNext()) {
              add(cursor.toDocumentRow())
            }
          }
        }
    }
  }

  private fun Cursor.toDocumentRow(): DocumentRow {
    val id = getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
    val name = getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
    val mime = getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
    val size = getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
    val modified = getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
    return DocumentRow(
      documentId = getString(id),
      name = getString(name),
      mimeType = if (mime < 0 || isNull(mime)) null else getString(mime),
      size = if (size < 0 || isNull(size)) null else getLong(size),
      // Providers that don't track it report 0: that is "won't say".
      lastModified = if (modified < 0 || isNull(modified)) null else getLong(modified).takeIf { it > 0 }
    )
  }

  fun onDetachedFromEngine() {
    scopes.clear()
  }

  /**
   * A live read grant on [uri] itself, or on the tree it belongs to: a
   * tree grant lives on the root, so a document inside it matches by
   * authority and tree ID.
   */
  @WorkerThread
  private fun hasPersistedReadGrant(contentResolver: ContentResolver, uri: Uri): Boolean {
    val treeId = if (DocumentsContract.isTreeUri(uri)) {
      DocumentsContract.getTreeDocumentId(uri)
    } else {
      null
    }
    return contentResolver.persistedUriPermissions.any { permission ->
      val granted = permission.uri
      permission.isReadPermission && (
        granted == uri || (
          treeId != null &&
            DocumentsContract.isTreeUri(granted) &&
            granted.authority == uri.authority &&
            DocumentsContract.getTreeDocumentId(granted) == treeId
          )
        )
    }
  }

  /**
   * The failure for a held grant whose document query came back empty:
   * `permission-lost` (detached) when the document's ExternalStorageProvider
   * volume is absent or unmounted, else `not-found`. Other providers are
   * opaque, so a detached volume there still reads as `not-found`.
   */
  @WorkerThread
  private fun missingDocument(documentUri: Uri): TaxonomyException =
    absentVolume(documentUri)
      ?: TaxonomyException(ErrorKind.NOT_FOUND, "No document at $documentUri")

  /**
   * `permission-lost` (`volume-absent`) when [documentUri] lives on an
   * ExternalStorageProvider volume that is absent or unmounted, else null.
   */
  @WorkerThread
  private fun absentVolume(documentUri: Uri, cause: Throwable? = null): TaxonomyException? {
    if (documentUri.authority != StorageVolumes.AUTHORITY) {
      return null
    }
    val volume = StorageVolumes.volumeOf(DocumentsContract.getDocumentId(documentUri))
    if (volume == null || isMounted(volume)) {
      return null
    }
    return TaxonomyException(
      ErrorKind.PERMISSION_LOST,
      "Storage volume of $documentUri is not mounted",
      cause,
      details = mapOf("reason" to "volume-absent")
    )
  }

  /**
   * Runs a provider call on [documentUri]. A removed volume does not
   * always read as a null row: once its root is gone the provider's tree
   * check throws `IllegalArgumentException("… No root for <uuid>")`, and a
   * plain document URI throws `FileNotFoundException`. The cause does not
   * cross Binder, so rather than match on the class or message, any
   * exception is first checked against the volume's state.
   */
  @WorkerThread
  private inline fun <T> onVolume(documentUri: Uri, block: () -> T): T =
    try {
      block()
    } catch (e: Exception) {
      val absent = absentVolume(documentUri, e) ?: throw e
      plugin.logDebug("Volume absent; the provider threw ${e.javaClass.name}: ${e.message}")
      throw absent
    }

  private fun isMounted(volume: StorageVolumes.Volume): Boolean {
    val storageManager = requireContext().getSystemService(StorageManager::class.java)
    val match = storageManager.storageVolumes.firstOrNull {
      when (volume) {
        StorageVolumes.Volume.Primary -> it.isPrimary
        is StorageVolumes.Volume.Uuid -> it.uuid.equals(volume.uuid, ignoreCase = true)
      }
    }
    return match?.state == Environment.MEDIA_MOUNTED ||
      match?.state == Environment.MEDIA_MOUNTED_READ_ONLY
  }

  /** The document to query for [uri]: a bare tree URI names its root. */
  private fun documentUriFor(uri: Uri): Uri =
    if (DocumentsContract.isTreeUri(uri) && !DocumentsContract.isDocumentUri(requireContext(), uri)) {
      DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
    } else {
      uri
    }

  private fun requireActivity() = (plugin.activity
    ?: throw FilePickerException("Illegal state, expected activity to be there."))

  // The application context only: this runs on the TaskQueue, and the
  // activity binding is main-hop state.
  private fun requireContext() = (plugin.applicationContext
    ?: throw FilePickerException("Illegal state, expected application context to be there."))

  private val CONTENT_PROVIDER_SCHEMES = setOf(
    ContentResolver.SCHEME_CONTENT,
    ContentResolver.SCHEME_FILE,
    ContentResolver.SCHEME_ANDROID_RESOURCE
  )

  @MainThread
  override fun onNewIntent(intent: Intent): Boolean {
    val data = intent.data
    val scheme = data?.scheme

    plugin.logDebug("onNewIntent($data)")
    if (data == null) {
      return false
    }
//    if (scheme == null || !CONTENT_PROVIDER_SCHEMES.contains(scheme)) {
//      plugin.logDebug("Not handling url $data (no supported scheme $CONTENT_PROVIDER_SCHEMES)")
//      return false
//    }
    // Decide here, synchronously on main, not in the launched coroutine:
    // by the time it runs, `init` may have drained the gate already.
    if (launchUrls.offer(data)) {
      plugin.launch { handleUriLogged(data) }
    }
    return true
  }

  @MainThread
  suspend fun init() {
    // `open` takes the queue in one step, before anything suspends, so an
    // intent arriving while these are handled goes straight to handleUri.
    for (uri in launchUrls.open()) {
      handleUriLogged(uri)
    }
  }

  @MainThread
  private suspend fun handleUriLogged(uri: Uri) {
    try {
      handleUri(uri)
    } catch (exception: Exception) {
      plugin.logDebug("Error while handling intent for $uri", exception)
    }
  }

  @MainThread
  private suspend fun handleUri(uri: Uri) {
    val scheme = uri.scheme ?: return
    val isFile = CONTENT_PROVIDER_SCHEMES.contains(scheme)
    if (isFile) {
      plugin.openFile(withContext(Dispatchers.IO) { copyContentUriAndReturnFileInfo(uri) })
    } else {
      plugin.handleOpenUri(uri)
    }
  }

  // Drop intake: the whole window is the drop target. No filtering or
  // classifying here; every drag is reported and callers decide.

  private var dragTargetView: View? = null

  private var dragInsideWindow = false

  private val dropIntakeListener = View.OnDragListener { _, event ->
    when (event.action) {
      DragEvent.ACTION_DRAG_STARTED -> plugin.logDebug("Drop intake: drag started.")
      DragEvent.ACTION_DRAG_ENTERED -> {
        dragInsideWindow = true
        plugin.dragEntered()
      }
      DragEvent.ACTION_DRAG_EXITED -> exitDrag()
      // After a drop the framework sends DROP then ENDED with no EXITED;
      // ENDED is also the only signal when the drag ends outside our window.
      DragEvent.ACTION_DRAG_ENDED -> exitDrag()
      DragEvent.ACTION_DROP -> handleDrop(event)
      // LOCATION carries nothing the Dart side needs.
      else -> {}
    }
    // Always accept: returning true for STARTED is required to receive DROP.
    true
  }

  // Callbacks run on the main thread, so no synchronization is needed.
  private fun exitDrag() {
    if (!dragInsideWindow) return
    dragInsideWindow = false
    plugin.dragExited()
  }

  // Takes over the content view's OnDragListener. View offers no getter
  // for a previously set listener, so a host-set listener cannot be
  // preserved or restored; detach clears ours back to null.
  private fun attachDropIntake(activity: Activity) {
    detachDropIntake()
    val content = activity.findViewById<View>(android.R.id.content)
    if (content == null) {
      plugin.logDebug("Drop intake: no content view, drag and drop disabled.")
      return
    }
    dragTargetView = content
    content.setOnDragListener(dropIntakeListener)
  }

  private fun detachDropIntake() {
    dragTargetView?.setOnDragListener(null)
    dragTargetView = null
    // The removed listener never sees ENDED; close the hover state here.
    exitDrag()
  }

  private fun handleDrop(event: DragEvent) {
    val clipData = event.clipData
    if (clipData == null) {
      plugin.logDebug("Drop intake: drop without ClipData, ignoring.")
      return
    }
    val uriCount = (0 until clipData.itemCount).count { clipData.getItemAt(it).uri != null }
    if (uriCount == 0) {
      plugin.logDebug("Drop intake: no file URIs in drop of ${clipData.itemCount} item(s), ignoring.")
      return
    }
    // Request drop permissions synchronously on the UI thread. Every copy
    // below must complete before permissions.release() runs: Dart only ever
    // receives paths to temp copies, never URIs we already let go of.
    val permissions = requireActivity().requestDragAndDropPermissions(event)
    plugin.launch {
      try {
        val files = withContext(Dispatchers.IO) { copyDropItems(clipData) }
        if (files.isEmpty()) {
          plugin.sendError("Drop intake: failed to copy $uriCount dropped file(s).")
        } else {
          // Deliver the subset first, then report the shortfall so callers
          // can tell a partial group from a complete one.
          plugin.handleDrop(files)
          if (files.size < uriCount) {
            plugin.sendError("Drop intake: copied ${files.size} of $uriCount file(s).")
          }
        }
      } catch (e: Exception) {
        plugin.logDebug("Drop intake: error handling drop.", e)
      } finally {
        permissions?.release()
      }
    }
  }

  @WorkerThread
  private fun copyDropItems(clipData: ClipData): List<Map<String, String>> {
    val files = mutableListOf<Map<String, String>>()
    for (i in 0 until clipData.itemCount) {
      val uri = clipData.getItemAt(i).uri
      if (uri == null) {
        plugin.logDebug("Drop intake: skipping item $i without URI.")
        continue
      }
      try {
        files += copyContentUriAndReturnFileInfo(
          uri,
          // Drop permissions are transient and cannot be persisted.
          attemptPersistablePermission = false,
          fileNameFallback = uri.lastPathSegment?.takeIf { it.isNotBlank() } ?: "dropped-file-$i"
        )
      } catch (e: Exception) {
        plugin.logDebug("Drop intake: failed to copy $uri.", e)
      }
    }
    return files
  }

}
