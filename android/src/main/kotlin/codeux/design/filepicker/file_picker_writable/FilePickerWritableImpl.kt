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
import android.system.Os
import android.system.OsConstants
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

    /**
     * How deep a recursive delete walks. Shared-storage paths end far
     * sooner (4096 bytes); the cap only stops a provider whose tree loops.
     */
    private const val MAX_WALK_DEPTH = 256

    /** FAT stores modification times in 2-second steps. */
    private const val MTIME_SLACK_MS = 2000L
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
   * Opens the file a live scope names and detaches its descriptor into
   * Dart's ownership (large-file-reads-plan §5). Never reads a byte.
   *
   * `openFileDescriptor`, never `openAssetFileDescriptor`: an asset
   * descriptor can be a sub-range whose start offset every positional read
   * would have to honor. `getStatSize` answers seekability and length in
   * one call (-1 for anything but a regular file: a pipe). `detachFd` hands
   * the fd over for good — never wrap an fd with `fromFd` without keeping
   * the wrapper alive, or its finalizer closes the fd mid-read.
   *
   * A revoked grant fails the open with `permission-lost` (fds opened
   * before keep reading). A provider exception first runs the volume check
   * (a pulled stick is `volume-absent`, whatever the provider threw).
   * Below the picked root, the tree check's `IllegalArgumentException`
   * means the file is gone, the same rule as the directory verbs.
   *
   * A directory is `not-a-file`, whichever way the provider answers it:
   * ExternalStorageProvider hands out a directory's fd (caught by `fstat`,
   * since `getStatSize` would call it a pipe), others refuse to open it
   * (caught by re-querying the row's MIME type after the failure, so the
   * happy path costs no extra query).
   */
  @WorkerThread
  fun openRead(token: String): Map<String, Any?> {
    val identifier = scopes.identifierOf(token)
      ?: throw TaxonomyException(ErrorKind.SCOPE_CLOSED, "Scope $token was released")
    val uri = Uri.parse(identifier)
    val contentResolver = requireContext().contentResolver
    if (!hasPersistedReadGrant(contentResolver, uri)) {
      throw TaxonomyException(ErrorKind.PERMISSION_LOST, "No persisted grant covers $uri")
    }
    val documentUri = documentUriFor(uri)
    val pfd = try {
      onVolume(documentUri) { contentResolver.openFileDescriptor(documentUri, "r") }
    } catch (e: TaxonomyException) {
      throw e
    } catch (e: Exception) {
      val isDirectory = try {
        queryRow(documentUri)?.isDirectory == true
      } catch (absent: TaxonomyException) {
        // The volume detached between the failed open and this query.
        throw absent
      } catch (_: Exception) {
        false
      }
      if (isDirectory) {
        throw TaxonomyException(ErrorKind.NOT_A_FILE, "$documentUri is a directory", e)
      }
      val isTreeRoot = DocumentsContract.isTreeUri(uri) &&
        DocumentsContract.getDocumentId(documentUri) == DocumentsContract.getTreeDocumentId(uri)
      if (e is IllegalArgumentException && !isTreeRoot) {
        throw missingDocument(documentUri, e)
      }
      throw e
    } ?: throw missingDocument(documentUri)
    val mode = try {
      Os.fstat(pfd.fileDescriptor).st_mode
    } catch (e: Exception) {
      pfd.close()
      throw e
    }
    if (OsConstants.S_ISDIR(mode)) {
      pfd.close()
      throw TaxonomyException(ErrorKind.NOT_A_FILE, "$documentUri is a directory")
    }
    val statSize = pfd.statSize
    val fd = pfd.detachFd()
    plugin.logDebug("openRead: fd $fd, statSize $statSize")
    return mapOf(
      "fd" to fd,
      "seekable" to (statSize >= 0),
      "length" to statSize.takeIf { it >= 0 }
    )
  }

  /**
   * Creates the file [name] under the directory a live scope token names
   * and detaches a write descriptor into Dart's ownership
   * (tree-writes-plan §5). Never writes a byte. Fail-if-exists by
   * lookup-first (no exclusive create exists here); a stored name that
   * differs is undone by [requireCreatedName]. A file that cannot be
   * opened once created is deleted again: it is ours, and empty.
   * `getStatSize` says whether the descriptor is a file (`canFsync`, and
   * positional writes) or a pipe.
   */
  @WorkerThread
  fun openWrite(token: String, name: String, mimeType: String): Map<String, Any?> {
    requireLeaf(name)
    val parent = requireWritableScope(token)
    if (lookupChildRow(parent, name) != null) {
      throw alreadyExists(name)
    }
    val contentResolver = requireContext().contentResolver
    val created = onVolume(parent.documentUri) {
      DocumentsContract.createDocument(contentResolver, parent.documentUri, mimeType, name)
    } ?: throw missingDocument(parent.documentUri)
    val row = rowBelowRoot(created) ?: throw missingDocument(created)
    requireCreatedName(parent, created, row, name)
    val pfd = try {
      onVolume(created) { contentResolver.openFileDescriptor(created, "w") }
        ?: throw IllegalStateException("The provider opened no descriptor for $created")
    } catch (e: Exception) {
      // Ours only while still empty: someone may have taken the name since.
      val stillEmpty = try {
        rowBelowRoot(created)?.size == 0L
      } catch (check: Exception) {
        false
      }
      if (stillEmpty) {
        deleteResidue(created)
      }
      throw e
    }
    val statSize = pfd.statSize
    if (statSize > 0) {
      // "w" does not truncate on current AOSP, so content here means the
      // name holds someone else's file by now: leave it alone.
      pfd.close()
      throw TaxonomyException(
        ErrorKind.ALREADY_EXISTS,
        "\"$name\" was replaced while it was being opened",
        details = mapOf("name" to name, "reason" to "replaced")
      )
    }
    val fd = pfd.detachFd()
    plugin.logDebug("openWrite: fd $fd, statSize $statSize")
    return mapOf(
      "fd" to fd,
      "identifier" to row.toResult(parent.treeUri)["identifier"],
      "canFsync" to (statSize >= 0)
    )
  }

  /**
   * Deletes an aborted write session's partial [identifier], only while
   * the file there is still the session's: SAF has no inode, so "still the
   * session's" is a file of [bytesWritten] bytes (when known: the root's
   * copy after a kill does not know) modified no earlier than [openedAt]
   * (less [MTIME_SLACK_MS] for FAT's 2-second times). The user may have
   * renamed the partial away and another file taken its name; that is
   * `not-found` with `reason: replaced`, and nothing is deleted. Gone is
   * success.
   */
  @WorkerThread
  fun abortPartial(identifier: String, bytesWritten: Long?, openedAt: Long) {
    val uri = Uri.parse(identifier)
    requireBelowRoot(uri)
    requireWriteGrant(uri)
    val documentUri = documentUriFor(uri)
    val row = rowBelowRoot(documentUri) ?: return
    val size = row.size
    val modified = row.lastModified
    val sameFile = !row.isDirectory &&
      (bytesWritten == null || size == null || size == bytesWritten) &&
      (modified == null || modified >= openedAt - MTIME_SLACK_MS)
    if (!sameFile) {
      throw TaxonomyException(
        ErrorKind.NOT_FOUND,
        "${row.name} is no longer this session's file: not deleted",
        details = mapOf(
          "reason" to "replaced",
          "size" to size,
          "written" to bytesWritten,
          "lastModified" to modified
        )
      )
    }
    deleteDocument(documentUri)
  }

  /**
   * The entry [identifier] names, or null when it is provably gone: the
   * stat a write session's commit returns.
   */
  @WorkerThread
  fun statEntry(identifier: String): Map<String, Any?>? {
    val uri = Uri.parse(identifier)
    if (!hasPersistedReadGrant(requireContext().contentResolver, uri)) {
      throw TaxonomyException(ErrorKind.PERMISSION_LOST, "No persisted grant covers $uri")
    }
    val row = rowBelowRoot(documentUriFor(uri)) ?: return null
    return row.toResult(treeUriOf(uri))
  }

  /**
   * Creates the directory [name] under the directory a live scope token
   * names (tree-writes-plan §5). The name is looked up first, so a taken
   * one is `already-exists` without trying; a stored name that differs
   * from the request is undone by [requireCreatedName].
   */
  @WorkerThread
  fun createDirectory(token: String, name: String): Map<String, Any?> {
    requireLeaf(name)
    val parent = requireWritableScope(token)
    if (lookupChildRow(parent, name) != null) {
      throw alreadyExists(name)
    }
    val contentResolver = requireContext().contentResolver
    val created = onVolume(parent.documentUri) {
      DocumentsContract.createDocument(
        contentResolver, parent.documentUri, DocumentsContract.Document.MIME_TYPE_DIR, name
      )
    } ?: throw missingDocument(parent.documentUri)
    val row = rowBelowRoot(created) ?: throw missingDocument(created)
    requireCreatedName(parent, created, row, name)
    return row.toResult(parent.treeUri)
  }

  /**
   * Deletes the document [identifier] names; one that is already gone is
   * success. A directory's children are the plugin's own depth-first walk
   * (provider-side recursion is discretionary, so never trusted), and a
   * non-empty one without [recursive] is `directory-not-empty`. Both are
   * decided by listing: best-effort against a concurrent writer.
   */
  @WorkerThread
  fun deleteEntry(identifier: String, recursive: Boolean) {
    val uri = Uri.parse(identifier)
    requireBelowRoot(uri)
    requireWriteGrant(uri)
    val documentUri = documentUriFor(uri)
    val row = rowBelowRoot(documentUri) ?: return
    if (row.isDirectory) {
      val directory = Directory(
        treeUriOf(uri), DocumentsContract.getDocumentId(documentUri), documentUri, isTreeRoot = false
      )
      val children = childrenBelowRoot(directory) ?: return
      if (children.isNotEmpty()) {
        if (!recursive) {
          throw TaxonomyException(
            ErrorKind.DIRECTORY_NOT_EMPTY, "${row.name} holds ${children.size} entries"
          )
        }
        deleteChildren(directory, children)
      }
    }
    deleteDocument(documentUri)
  }

  /**
   * Moves [identifier] from the directory [sourceToken] names into the one
   * [targetToken] names, renamed to [newName] when given (tree-writes-plan
   * §4/§5). Taken target names are refused before anything moves; a
   * parent change runs `moveDocument`, then `renameDocument`, rolling the
   * move back when the rename fails.
   */
  @WorkerThread
  fun moveEntry(
    identifier: String,
    sourceToken: String,
    targetToken: String,
    newName: String?
  ): Map<String, Any?> {
    if (newName != null) {
      requireLeaf(newName)
    }
    val uri = Uri.parse(identifier)
    requireBelowRoot(uri)
    val source = requireWritableScope(sourceToken)
    val target = requireWritableScope(targetToken)
    requireWriteGrant(uri)
    val itemUri = documentUriFor(uri)
    val itemId = DocumentsContract.getDocumentId(itemUri)
    requireSameVolume(uri, itemId, source, target)
    val row = rowBelowRoot(itemUri) ?: throw missingDocument(itemUri)
    requireChildOf(source, itemId)
    val finalName = newName ?: row.name
    if (source.documentId == target.documentId) {
      if (finalName == row.name) {
        return row.toResult(target.treeUri)
      }
      requireFree(target, finalName)
      val renamed = try {
        renameVerified(target, itemUri, row.name, finalName)
      } catch (e: RenamedBack) {
        throw e.error
      }
      return (rowBelowRoot(renamed) ?: throw missingDocument(renamed)).toResult(target.treeUri)
    }
    // Both names up front: a move must never strand the entry under a name
    // the rename then cannot take.
    requireFree(target, row.name)
    if (finalName != row.name) {
      requireFree(target, finalName)
    }
    val moved = moveDocument(itemUri, source, target, row.name)
    if (finalName == row.name) {
      return (rowBelowRoot(moved) ?: throw missingDocument(moved)).toResult(target.treeUri)
    }
    val renamed = try {
      renameVerified(target, moved, row.name, finalName)
    } catch (e: RenamedBack) {
      // Back under its original name, at the URI the rename back returned
      // (the ID may have changed twice): roll the move back from there.
      moveBack(e.restored, source, target, e.error)
      throw e.error
    } catch (e: TaxonomyException) {
      if (e.kind == ErrorKind.MOVE_PARTIAL) {
        throw e
      }
      if (e.details["reason"] == "volume-absent") {
        // The rename may or may not have landed before the volume went:
        // a rollback now would act on a guess.
        throw locationUnknown(e, moved, target, finalName)
      }
      moveBack(moved, source, target, e)
      throw e
    } catch (e: Exception) {
      moveBack(moved, source, target, e)
      throw e
    }
    return (rowBelowRoot(renamed) ?: throw missingDocument(renamed)).toResult(target.treeUri)
  }

  /**
   * [renameVerified] undid a rename it could not accept: the entry is back
   * under its original name at [restored], and [error] says why.
   */
  private class RenamedBack(val restored: Uri, val error: TaxonomyException) :
    Exception(error.message, error)

  /**
   * `volume-absent` mid-move, after the move landed: the entry is under
   * [target], under its original name or already under [finalName]. Both
   * candidates go in the details (the second only where the ID can be
   * derived), so the caller can look once the volume is back.
   */
  private fun locationUnknown(
    cause: TaxonomyException,
    moved: Uri,
    target: Directory,
    finalName: String
  ): TaxonomyException {
    val candidates = mutableListOf(moved.toString())
    if (target.treeUri.authority == StorageVolumes.AUTHORITY) {
      candidates += DocumentsContract.buildDocumentUriUsingTree(
        target.treeUri, StorageVolumes.childDocumentId(target.documentId, finalName)
      ).toString()
    }
    return TaxonomyException(
      ErrorKind.PERMISSION_LOST,
      "The volume went away mid-move; the entry is at one of $candidates",
      cause,
      details = mapOf("reason" to "volume-absent", "state" to "unknown", "candidates" to candidates)
    )
  }

  private fun requireLeaf(name: String) {
    if (!isLeafName(name)) {
      throw TaxonomyException(ErrorKind.INVALID_NAME, "Not a single leaf name: \"$name\"")
    }
  }

  /**
   * The directory a live scope token names, under a persisted write grant
   * (`scope-closed`, `permission-lost`, `not-a-directory`, `not-found`).
   */
  @WorkerThread
  private fun requireWritableScope(token: String): Directory {
    val identifier = scopes.identifierOf(token)
      ?: throw TaxonomyException(ErrorKind.SCOPE_CLOSED, "Scope $token was released")
    requireWriteGrant(Uri.parse(identifier))
    return requireDirectory(identifier)
  }

  /**
   * `permission-lost` unless a persisted write grant covers [uri]; a
   * read-only grant (openDirectory accepts one) says so in the details.
   */
  @WorkerThread
  private fun requireWriteGrant(uri: Uri) {
    val contentResolver = requireContext().contentResolver
    if (hasPersistedGrant(contentResolver, uri, write = true)) {
      return
    }
    if (hasPersistedReadGrant(contentResolver, uri)) {
      throw TaxonomyException(
        ErrorKind.PERMISSION_LOST,
        "The grant covering $uri is read-only",
        details = mapOf("reason" to "read-only")
      )
    }
    throw TaxonomyException(ErrorKind.PERMISSION_LOST, "No persisted grant covers $uri")
  }

  /**
   * `root-protected` for a picker's own result: a tree's root, or a single
   * picked document (not a tree URI at all). Only entries below a picked
   * folder may be deleted or moved, so one wrong identifier cannot take a
   * whole pick with it. On ExternalStorageProvider the ID must be in the
   * one shape [StorageVolumes.isStrictlyBelow] accepts: other spellings
   * can resolve to the root itself.
   */
  private fun requireBelowRoot(uri: Uri) {
    val isPickedRoot = if (!DocumentsContract.isTreeUri(uri)) {
      true
    } else {
      val treeId = DocumentsContract.getTreeDocumentId(uri)
      val documentId = DocumentsContract.getDocumentId(documentUriFor(uri))
      if (uri.authority == StorageVolumes.AUTHORITY) {
        !StorageVolumes.isStrictlyBelow(treeId, documentId)
      } else {
        documentId == treeId
      }
    }
    if (isPickedRoot) {
      throw TaxonomyException(
        ErrorKind.ROOT_PROTECTED,
        "$uri is a picked root: only entries inside a picked folder can be deleted or moved"
      )
    }
  }

  private fun treeUriOf(uri: Uri): Uri =
    DocumentsContract.buildTreeDocumentUri(uri.authority, DocumentsContract.getTreeDocumentId(uri))

  /**
   * The row of a document below a tree's root, or null only when it is
   * provably gone ([requireGone]). A detached volume is thrown as
   * `volume-absent`, and an absence that cannot be proven stays loud:
   * "gone" lets a delete report success, so it is never a guess.
   */
  @WorkerThread
  private fun rowBelowRoot(documentUri: Uri): DocumentRow? {
    val (row, cause) = try {
      queryRow(documentUri) to null
    } catch (e: IllegalArgumentException) {
      null to e
    }
    if (row != null) {
      return row
    }
    absentVolume(documentUri, cause)?.let { throw it }
    requireGone(documentUri, cause)
    return null
  }

  /**
   * Throws unless an absent row means the document is gone. A dead
   * provider's query returns null too (`ContentResolver.query` swallows the
   * `RemoteException`), and a failing stick throws other
   * `IllegalArgumentException`s ("Failed to canonicalize"). On
   * ExternalStorageProvider a missing document below the root is the tree
   * check's "Missing file for", and the nearest ancestor that exists must
   * be a live directory (its parent may be gone too, inside a deleted
   * folder). Other providers are opaque: there a null row counts as gone
   * only while the tree's root still answers.
   */
  @WorkerThread
  private fun requireGone(documentUri: Uri, cause: IllegalArgumentException?) {
    val treeUri = treeUriOf(documentUri)
    val treeId = DocumentsContract.getTreeDocumentId(documentUri)
    val proven = if (documentUri.authority == StorageVolumes.AUTHORITY) {
      cause?.message?.contains("Missing file for") == true &&
        hasLiveAncestor(treeUri, treeId, DocumentsContract.getDocumentId(documentUri))
    } else {
      val root = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeId)
      cause == null && (try {
        queryRow(root)
      } catch (e: IllegalArgumentException) {
        null
      }) != null
    }
    if (!proven) {
      val answer = if (cause == null) "returned no row" else "threw: ${cause.message}"
      throw IllegalStateException("Cannot tell whether $documentUri is gone: the provider $answer", cause)
    }
  }

  /**
   * Walks up from [documentId] to the nearest ancestor that exists: true
   * when that is a live directory (the tree root included), false for any
   * other answer, so that only a plain "Missing file for" chain ending in a
   * live directory reads as gone.
   */
  @WorkerThread
  private fun hasLiveAncestor(treeUri: Uri, treeId: String, documentId: String): Boolean {
    var id = StorageVolumes.parentDocumentId(documentId) ?: return false
    while (true) {
      val isRoot = id == treeId
      if (!isRoot && !StorageVolumes.isStrictlyBelow(treeId, id)) {
        return false
      }
      val row = try {
        queryRow(DocumentsContract.buildDocumentUriUsingTree(treeUri, id))
      } catch (e: IllegalArgumentException) {
        if (isRoot || e.message?.contains("Missing file for") != true) {
          return false
        }
        id = StorageVolumes.parentDocumentId(id) ?: return false
        continue
      }
      return row?.isDirectory == true
    }
  }

  /**
   * [directory]'s children, or null when it is provably gone: a listing
   * that fails is decided by the directory's own row ([rowBelowRoot]), so
   * a failing provider stays loud.
   */
  @WorkerThread
  private fun childrenBelowRoot(directory: Directory): List<DocumentRow>? {
    val children = try {
      queryChildren(directory)
    } catch (e: IllegalArgumentException) {
      null
    }
    if (children != null) {
      return children
    }
    rowBelowRoot(directory.documentUri) ?: return null
    throw IllegalStateException("The provider listed nothing for ${directory.documentUri}, which still exists")
  }

  /**
   * Depth-first: every child before its directory. An opaque provider's
   * graph may hold a document twice or loop, so each document is visited
   * once, and the walk refuses to go deeper than [MAX_WALK_DEPTH] levels.
   */
  @WorkerThread
  private fun deleteChildren(
    directory: Directory,
    children: List<DocumentRow>,
    visited: MutableSet<String> = mutableSetOf(directory.documentId),
    depth: Int = 1
  ) {
    if (depth > MAX_WALK_DEPTH) {
      throw IllegalStateException(
        "More than $MAX_WALK_DEPTH levels below ${directory.documentUri}: refusing to walk deeper"
      )
    }
    for (child in children) {
      if (!visited.add(child.documentId)) {
        continue
      }
      val childUri = DocumentsContract.buildDocumentUriUsingTree(directory.treeUri, child.documentId)
      if (child.isDirectory) {
        val sub = Directory(directory.treeUri, child.documentId, childUri, isTreeRoot = false)
        childrenBelowRoot(sub)?.let { deleteChildren(sub, it, visited, depth + 1) }
      }
      deleteDocument(childUri)
    }
  }

  /** Deletes one document; one that is gone by now is success. */
  @WorkerThread
  private fun deleteDocument(documentUri: Uri) {
    val contentResolver = requireContext().contentResolver
    val deleted = try {
      onVolume(documentUri) { DocumentsContract.deleteDocument(contentResolver, documentUri) }
    } catch (e: TaxonomyException) {
      throw e
    } catch (e: Exception) {
      // Gone by now is success; anything unproven keeps the original error.
      val gone = try {
        rowBelowRoot(documentUri) == null
      } catch (check: TaxonomyException) {
        throw check
      } catch (check: Exception) {
        false
      }
      if (gone) {
        return
      }
      throw e
    }
    if (!deleted && rowBelowRoot(documentUri) != null) {
      throw IllegalStateException("The provider did not delete $documentUri")
    }
  }

  /** Deletes a document the plugin just created by mistake, logging a failure. */
  @WorkerThread
  private fun deleteResidue(documentUri: Uri) {
    try {
      deleteDocument(documentUri)
    } catch (e: Exception) {
      plugin.logWarning("Could not delete the residue $documentUri: $e")
    }
  }

  private fun alreadyExists(name: String, extra: Map<String, Any?> = emptyMap()) =
    TaxonomyException(ErrorKind.ALREADY_EXISTS, "\"$name\" is taken", details = mapOf("name" to name) + extra)

  /** `already-exists` when [name] is taken under [directory]. */
  @WorkerThread
  private fun requireFree(directory: Directory, name: String) {
    if (lookupChildRow(directory, name) != null) {
      throw alreadyExists(name)
    }
  }

  /**
   * Undoes a create whose stored name is not the requested [name], then
   * throws `already-exists` when [name] is taken by now (a concurrent
   * create, and the provider auto-renamed ours), else `invalid-name` (the
   * provider cleaned the name). Only a residue that is provably fresh, an
   * empty directory or a file of size 0, is deleted: a provider may hand
   * back an EXISTING entry for the cleaned name (ExternalStorageProvider
   * never does; it always makes a new one), and deleting that would delete
   * the user's data. Anything else is left alone, its identifier in the
   * details.
   */
  @WorkerThread
  private fun requireCreatedName(parent: Directory, created: Uri, row: DocumentRow, name: String) {
    if (row.name == name) {
      return
    }
    val taken = lookupChildRow(parent, name) != null
    val residue = Directory(parent.treeUri, DocumentsContract.getDocumentId(created), created, isTreeRoot = false)
    // Fresh: an empty directory, or a file of size 0 (openWrite's create),
    // the latter only on ExternalStorageProvider, which always creates a
    // new file: elsewhere an empty file handed back for a cleaned name may
    // be the user's own (an empty marker file).
    val isFresh = if (row.isDirectory) {
      try {
        childrenBelowRoot(residue)?.isEmpty() == true
      } catch (e: Exception) {
        false
      }
    } else {
      row.size == 0L && created.authority == StorageVolumes.AUTHORITY
    }
    val extra = if (isFresh) {
      deleteResidue(created)
      emptyMap()
    } else {
      plugin.logWarning("Not deleting $created: not provably fresh (empty)")
      mapOf("identifier" to row.toResult(parent.treeUri)["identifier"], "residue" to "kept")
    }
    if (taken) {
      throw alreadyExists(name, extra)
    }
    throw invalidName(name, row.name, extra)
  }

  private fun invalidName(requested: String, actual: String, extra: Map<String, Any?> = emptyMap()) =
    TaxonomyException(
      ErrorKind.INVALID_NAME,
      "The provider stored \"$requested\" as \"$actual\"",
      details = mapOf("requested" to requested, "actual" to actual) + extra
    )

  /**
   * `unsupported-move` unless the entry and both parents share a provider,
   * and on ExternalStorageProvider a volume: a move across them is a copy
   * plus a delete, out of scope for v1.
   */
  private fun requireSameVolume(uri: Uri, itemId: String, source: Directory, target: Directory) {
    val authority = uri.authority
    val sameProvider = source.treeUri.authority == authority && target.treeUri.authority == authority
    val sameVolume = authority != StorageVolumes.AUTHORITY ||
      StorageVolumes.volumeOf(itemId) == StorageVolumes.volumeOf(target.documentId)
    if (!sameProvider || !sameVolume) {
      throw TaxonomyException(
        ErrorKind.UNSUPPORTED_MOVE,
        "Moving $uri into ${target.documentUri} crosses a provider or volume: copy, then delete"
      )
    }
  }

  /**
   * `not-found` unless [itemId] sits directly in [source]: derived from
   * the ID on ExternalStorageProvider, by listing elsewhere.
   */
  @WorkerThread
  private fun requireChildOf(source: Directory, itemId: String) {
    val isChild = if (source.treeUri.authority == StorageVolumes.AUTHORITY) {
      StorageVolumes.parentDocumentId(itemId) == source.documentId
    } else {
      requireChildren(source).any { it.documentId == itemId }
    }
    if (!isChild) {
      throw TaxonomyException(
        ErrorKind.NOT_FOUND,
        "$itemId is not directly in ${source.documentId}",
        details = mapOf("reason" to "not-a-child")
      )
    }
  }

  /**
   * `moveDocument` from [source] into [target], returning the moved
   * document's URI under the target's tree. The provider throws on a
   * collision rather than renaming; a name taken since the pre-check reads
   * as `already-exists`.
   */
  @WorkerThread
  private fun moveDocument(itemUri: Uri, source: Directory, target: Directory, name: String): Uri {
    val contentResolver = requireContext().contentResolver
    val moved = try {
      onVolume(itemUri) {
        DocumentsContract.moveDocument(contentResolver, itemUri, source.documentUri, target.documentUri)
      }
    } catch (e: TaxonomyException) {
      throw e
    } catch (e: Exception) {
      if (lookupChildRow(target, name) != null && rowBelowRoot(itemUri) != null) {
        throw alreadyExists(name)
      }
      throw e
    } ?: throw IllegalStateException("The provider did not move $itemUri")
    return DocumentsContract.buildDocumentUriUsingTree(target.treeUri, DocumentsContract.getDocumentId(moved))
  }

  /**
   * The rollback of a combined move + rename whose rename failed: moves
   * [moved] back into [source]. If that fails too, the entry is stranded
   * in [target] under its original name: `move-partial`, carrying its
   * identifier there.
   */
  @WorkerThread
  private fun moveBack(moved: Uri, source: Directory, target: Directory, cause: Exception) {
    val contentResolver = requireContext().contentResolver
    try {
      onVolume(moved) {
        DocumentsContract.moveDocument(contentResolver, moved, target.documentUri, source.documentUri)
      } ?: throw IllegalStateException("The provider did not move $moved back")
    } catch (e: Exception) {
      plugin.logWarning("Rolling back the move of $moved failed: $e")
      throw movePartial(moved, cause)
    }
  }

  /**
   * `move-partial`: the entry is at [actual], or, when the last step may
   * have landed unseen, at [alsoAt] (both then in `candidates`).
   */
  private fun movePartial(actual: Uri, cause: Throwable, alsoAt: Uri? = null) = TaxonomyException(
    ErrorKind.MOVE_PARTIAL,
    if (alsoAt == null) "The entry was left at $actual" else "The entry was left at $actual or $alsoAt",
    cause,
    details = mapOf("identifier" to actual.toString()) +
      (alsoAt?.let { mapOf("candidates" to listOf(actual.toString(), it.toString())) } ?: emptyMap())
  )

  /**
   * `renameDocument` of [documentUri] (named [original], under [parent])
   * to [name], returning the renamed URI. The stored name is verified: a
   * mismatch is renamed back to [original] (never deleted: it is the
   * user's entry), then [RenamedBack] carrying where it is now and the
   * error: `already-exists` when [name] is taken by now, else
   * `invalid-name`. A rename back that fails or lands elsewhere is
   * `move-partial`.
   */
  @WorkerThread
  private fun renameVerified(parent: Directory, documentUri: Uri, original: String, name: String): Uri {
    val renamed = rename(parent, documentUri, name)
    val row = rowBelowRoot(renamed) ?: throw missingDocument(renamed)
    if (row.name == name) {
      return renamed
    }
    // From here the entry's place is known (renamed, as row.name): every
    // failure says so instead of letting a caller guess.
    val taken = try {
      lookupChildRow(parent, name) != null
    } catch (e: Exception) {
      throw movePartial(renamed, e)
    }
    val restored = try {
      rename(parent, renamed, original)
    } catch (e: Exception) {
      // A rename back that failed with the volume may have landed too.
      val alsoAt = if (e is TaxonomyException && e.details["reason"] == "volume-absent" &&
        parent.treeUri.authority == StorageVolumes.AUTHORITY
      ) {
        DocumentsContract.buildDocumentUriUsingTree(
          parent.treeUri, StorageVolumes.childDocumentId(parent.documentId, original)
        )
      } else {
        null
      }
      throw movePartial(renamed, e, alsoAt)
    }
    val restoredRow = try {
      rowBelowRoot(restored)
    } catch (e: Exception) {
      throw movePartial(restored, e)
    }
    if (restoredRow?.name != original) {
      throw movePartial(restored, IllegalStateException("Renamed back as ${restoredRow?.name}"))
    }
    throw RenamedBack(restored, if (taken) alreadyExists(name) else invalidName(name, row.name))
  }

  /** One `renameDocument`, as a URI under [parent]'s tree. */
  @WorkerThread
  private fun rename(parent: Directory, documentUri: Uri, name: String): Uri {
    val contentResolver = requireContext().contentResolver
    // Null when the provider kept the document ID.
    val renamed = onVolume(documentUri) {
      DocumentsContract.renameDocument(contentResolver, documentUri, name)
    } ?: documentUri
    return DocumentsContract.buildDocumentUriUsingTree(parent.treeUri, DocumentsContract.getDocumentId(renamed))
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
    return lookupChildRow(directory, name)?.toResult(directory.treeUri)
  }

  /** [lookupChild]'s answer as a row, for verbs that hold the directory. */
  @WorkerThread
  private fun lookupChildRow(directory: Directory, name: String): DocumentRow? =
    if (directory.treeUri.authority == StorageVolumes.AUTHORITY) {
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
        val parent = directoryRow(directory.documentUri, directory.isTreeRoot)
        if (!parent.isDirectory) {
          // Replaced by a file mid-call.
          throw TaxonomyException(ErrorKind.NOT_A_DIRECTORY, "${parent.name} is not a directory")
        }
        // Usually the absent child ("Missing file for …", logged above).
        // The residual case is a live parent whose child could not be
        // canonicalized (a failing stick): the answer is still absent, but
        // it is kept visible. The message picks the log level only, never
        // the answer.
        if (e.message?.contains("Missing file for") != true) {
          plugin.logWarning("lookupChild: answering absent for a live parent after: ${e.message}")
        }
        null
      } ?: run {
        // A volume detached since requireDirectory reads as a null row.
        absentVolume(childUri)?.let { throw it }
        null
      }
    } else {
      requireChildren(directory).firstOrNull { it.name == name }
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
    // The provider's message ("Missing file for", "Failed to
    // canonicalize", "No root for") travels on as the cause, so details
    // can tell them apart.
    val (row, cause) = try {
      queryRow(documentUri) to null
    } catch (e: IllegalArgumentException) {
      if (isTreeRoot) {
        throw e
      }
      plugin.logDebug("Directory query threw ${e.message}; treating it as gone")
      null to e
    }
    return row ?: throw missingDocument(documentUri, cause)
  }

  /**
   * All children of [directory], else [missingDocument]: a folder removed
   * since [requireDirectory] shows up here, as a null cursor or, below the
   * tree root, as the tree check's `IllegalArgumentException`.
   */
  @WorkerThread
  private fun requireChildren(directory: Directory): List<DocumentRow> {
    val (children, cause) = try {
      queryChildren(directory) to null
    } catch (e: IllegalArgumentException) {
      if (directory.isTreeRoot) {
        throw e
      }
      plugin.logDebug("Children query threw ${e.message}; treating the directory as gone")
      null to e
    }
    return children ?: throw missingDocument(directory.documentUri, cause)
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
  private fun hasPersistedReadGrant(contentResolver: ContentResolver, uri: Uri): Boolean =
    hasPersistedGrant(contentResolver, uri, write = false)

  /** [hasPersistedReadGrant], for a read grant, or with [write] a write one. */
  @WorkerThread
  private fun hasPersistedGrant(contentResolver: ContentResolver, uri: Uri, write: Boolean): Boolean {
    val treeId = if (DocumentsContract.isTreeUri(uri)) {
      DocumentsContract.getTreeDocumentId(uri)
    } else {
      null
    }
    return contentResolver.persistedUriPermissions.any { permission ->
      val granted = permission.uri
      (if (write) permission.isWritePermission else permission.isReadPermission) && (
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
  private fun missingDocument(documentUri: Uri, cause: Throwable? = null): TaxonomyException =
    absentVolume(documentUri, cause)
      ?: TaxonomyException(ErrorKind.NOT_FOUND, "No document at $documentUri", cause)

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
