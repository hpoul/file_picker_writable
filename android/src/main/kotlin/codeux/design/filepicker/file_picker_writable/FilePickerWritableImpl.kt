package codeux.design.filepicker.file_picker_writable

import android.app.Activity
import android.app.Activity.RESULT_OK
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import androidx.annotation.MainThread
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

interface ActivityProvider : CoroutineScope {
  val activity: Activity?
  fun logDebug(message: String, e: Throwable? = null)
  @MainThread
  fun openFile(fileInfo: Map<String, String>)
  @MainThread
  fun handleOpenUri(uri: Uri)
}

class FilePickerWritableImpl(
  private val plugin: ActivityProvider
) : PluginRegistry.ActivityResultListener, PluginRegistry.NewIntentListener {

  companion object {
    const val REQUEST_CODE_OPEN_FILE = 40832
    const val REQUEST_CODE_CREATE_FILE = 40833
    const val REQUEST_CODE_OPEN_DIRECTORY = 40834
  }

  private var filePickerCreateFile: File? = null
  private var filePickerResult: MethodChannel.Result? = null

  private var isInitialized = false
  private var initOpenUrl: Uri? = null


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
      plugin.logDebug("exception while launching file picker", e)
      result.error(
        "FilePickerNotAvailable",
        "Unable to start file picker, $e",
        null
      )
    }
  }

  @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
  @MainThread
  fun openDirectoryPicker(result: MethodChannel.Result, initialDirUri: String?) {
    if (filePickerResult != null) {
      throw FilePickerException("Invalid lifecycle, only one call at a time.")
    }
    filePickerResult = result
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        if (initialDirUri != null) {
          try {
            val parsedUri = Uri.parse(initialDirUri).let {
              val context = requireActivity().applicationContext
              if (DocumentsContract.isDocumentUri(context, it)) {
                it
              } else {
                DocumentsContract.buildDocumentUriUsingTree(
                  it,
                  DocumentsContract.getTreeDocumentId(it)
                )
              }
            }
            putExtra(DocumentsContract.EXTRA_INITIAL_URI, parsedUri)
          } catch (e: Exception) {
            plugin.logDebug("exception while preparing document picker initial dir", e)
          }
        }
      }
    }
    val activity = requireActivity()
    try {
      activity.startActivityForResult(intent, REQUEST_CODE_OPEN_DIRECTORY)
    } catch (e: ActivityNotFoundException) {
      filePickerResult = null
      plugin.logDebug("exception while launching directory picker", e)
      result.error(
        "DirectoryPickerNotAvailable",
        "Unable to start directory picker, $e",
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

  override fun onActivityResult(
    requestCode: Int,
    resultCode: Int,
    data: Intent?
  ): Boolean {
    if (!arrayOf(REQUEST_CODE_OPEN_FILE, REQUEST_CODE_CREATE_FILE, REQUEST_CODE_OPEN_DIRECTORY).contains(
        requestCode
      )) {
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
    plugin.launch {
      try {
        when (requestCode) {
          REQUEST_CODE_OPEN_FILE -> {
            val fileUri = data?.data
            if (fileUri != null) {
              plugin.logDebug("Got result $fileUri")
              handleFileUriResponse(result, fileUri)
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
            handleFileUriCreateResponse(
              result,
              fileUri,
              initialFileContent
            )
          }
          REQUEST_CODE_OPEN_DIRECTORY -> {
            val directoryUri = data?.data
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
              throw FilePickerException("illegal state - get a directory response on an unsupported OS version")
            }
            if (directoryUri != null) {
              plugin.logDebug("Got result $directoryUri")
              handleDirectoryUriResponse(result, directoryUri)
            } else {
              plugin.logDebug("Got RESULT_OK with null directoryUri?")
              result.success(null)
            }
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

  @MainThread
  private suspend fun handleFileUriCreateResponse(
    result: MethodChannel.Result,
    fileUri: Uri,
    initialFileContent: File
  ) {
    val activity = requireActivity()
    val contentResolver = activity.applicationContext.contentResolver
    val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
      Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    contentResolver.takePersistableUriPermission(fileUri, takeFlags)

    writeFileWithIdentifier(result, fileUri.toString(), initialFileContent)
  }

  @MainThread
  private suspend fun handleFileUriResponse(
    result: MethodChannel.Result,
    fileUri: Uri
  ) {
    copyContentUriAndReturn(result, fileUri)
  }

  @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
  @MainThread
  private suspend fun handleDirectoryUriResponse(
    result: MethodChannel.Result,
    directoryUri: Uri
  ) {
    result.success(
      getDirectoryInfo(directoryUri)
    )
  }

  @MainThread
  suspend fun readFileWithIdentifier(
    result: MethodChannel.Result,
    identifier: String
  ) {
    copyContentUriAndReturn(result, Uri.parse(identifier))
  }

  @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
  @MainThread
  suspend fun getDirectory(
    result: MethodChannel.Result,
    rootUri: String,
    fileUri: String
  ) {
    val activity = requireActivity()

    val root = Uri.parse(rootUri)
    val leaf = Uri.parse(fileUri)
    val leafUnderRoot = DocumentsContract.buildDocumentUriUsingTree(
      root,
      DocumentsContract.getDocumentId(leaf)
    )

    if (!fileExists(leafUnderRoot, activity.applicationContext.contentResolver)) {
      result.error(
        "InvalidArguments",
        "The supplied fileUri $fileUri is not a child of $rootUri",
        null
      )
      return
    }

    val ret = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      getParent(leafUnderRoot, activity.applicationContext)
    } else {
      null
    } ?: findParent(root, leaf, activity.applicationContext)


    result.success(mapOf(
      "identifier" to ret.toString(),
      "persistable" to "true",
      "uri" to ret.toString()
    ))
  }

  @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
  @MainThread
  suspend fun resolveRelativePath(
    result: MethodChannel.Result,
    parentIdentifier: String,
    relativePath: String
  ) {
    val activity = requireActivity()

    val resolvedUri = resolveRelativePath(Uri.parse(parentIdentifier), relativePath, activity.applicationContext)
    if (resolvedUri != null) {
      val displayName = getDisplayName(resolvedUri, activity.applicationContext.contentResolver)
      val isDirectory = isDirectory(resolvedUri, activity.applicationContext.contentResolver)
      result.success(mapOf(
        "identifier" to resolvedUri.toString(),
        "persistable" to "true",
        "fileName" to displayName,
        "uri" to resolvedUri.toString(),
        "isDirectory" to isDirectory.toString()
      ))
    } else {
      result.error("FileNotFound", "$relativePath could not be located relative to $parentIdentifier", null)
    }
  }

  @MainThread
  private suspend fun copyContentUriAndReturn(
    result: MethodChannel.Result,
    fileUri: Uri
  ) {

    result.success(
      copyContentUriAndReturnFileInfo(fileUri)
    )
  }

  @MainThread
  private suspend fun copyContentUriAndReturnFileInfo(fileUri: Uri): Map<String, String> {
    val activity = requireActivity()

    val contentResolver = activity.applicationContext.contentResolver

    return withContext(Dispatchers.IO) {
      var persistable = false
      try {
        val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
          Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        contentResolver.takePersistableUriPermission(fileUri, takeFlags)
        persistable = true
      } catch (e: SecurityException) {
        plugin.logDebug("Couldn't take persistable URI permission on $fileUri", e)
      }

      val fileName = getDisplayName(fileUri, contentResolver)

      val tempFile =
        File.createTempFile(
          // use a maximum of 20 characters.
          // It's just a temp file name so does not really matter.
          fileName.take(20),
          null, activity.cacheDir
        )
      plugin.logDebug("Copy file $fileUri to $tempFile")
      contentResolver.openInputStream(fileUri).use { input ->
        requireNotNull(input)
        tempFile.outputStream().use { output ->
          input.copyTo(output)
        }
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

  @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
  @MainThread
  private suspend fun getDirectoryInfo(directoryUri: Uri): Map<String, String> {
    val activity = requireActivity()

    val contentResolver = activity.applicationContext.contentResolver

    return withContext(Dispatchers.IO) {
      var persistable = false
      try {
        val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
          Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        contentResolver.takePersistableUriPermission(directoryUri, takeFlags)
        persistable = true
      } catch (e: SecurityException) {
        plugin.logDebug("Couldn't take persistable URI permission on $directoryUri", e)
      }
      // URI as returned from picker is just a tree URI, but we need a document URI for getting the display name
      val treeDocUri = DocumentsContract.buildDocumentUriUsingTree(
        directoryUri,
        DocumentsContract.getTreeDocumentId(directoryUri)
      )
      mapOf(
        "identifier" to directoryUri.toString(),
        "persistable" to persistable.toString(),
        "uri" to directoryUri.toString(),
        "fileName" to getDisplayName(treeDocUri, contentResolver)
      )
    }
  }

  fun onDetachedFromActivity(binding: ActivityPluginBinding) {
    binding.removeActivityResultListener(this)
  }

  fun onAttachedToActivity(binding: ActivityPluginBinding) {
    binding.addActivityResultListener(this)
    binding.addOnNewIntentListener(this)
    onNewIntent(binding.activity.intent)
  }

  @MainThread
  suspend fun writeFileWithIdentifier(
    result: MethodChannel.Result,
    identifier: String,
    file: File
  ) {
    if (!file.exists()) {
      throw FilePickerException("File at source not found. $file")
    }
    val fileUri = Uri.parse(identifier)
    val activity = requireActivity()
    val contentResolver = activity.contentResolver
    withContext(Dispatchers.IO) {
      contentResolver.openOutputStream(fileUri, "w").use { output ->
        require(output != null)
        file.inputStream().use { input ->
          input.copyTo(output)
        }
      }
    }
    copyContentUriAndReturn(result, fileUri)
  }

  fun disposeIdentifier(identifier: String) {
    val activity = requireActivity()
    val contentResolver = activity.applicationContext.contentResolver
    val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
      Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    contentResolver.releasePersistableUriPermission(Uri.parse(identifier), takeFlags)
  }

  private fun requireActivity() = (plugin.activity
    ?: throw FilePickerException("Illegal state, expected activity to be there."))

  private val CONTENT_PROVIDER_SCHEMES = setOf(
    ContentResolver.SCHEME_CONTENT,
    ContentResolver.SCHEME_FILE,
    ContentResolver.SCHEME_ANDROID_RESOURCE
  )

  override fun onNewIntent(intent: Intent?): Boolean {
    val data = intent?.data
    val scheme = data?.scheme

    plugin.logDebug("onNewIntent($data)")
    if (data == null) {
      return false
    }
//    if (scheme == null || !CONTENT_PROVIDER_SCHEMES.contains(scheme)) {
//      plugin.logDebug("Not handling url $data (no supported scheme $CONTENT_PROVIDER_SCHEMES)")
//      return false
//    }
    plugin.launch {
      try {
        if (isInitialized) {
          handleUri(data)
        } else {
          initOpenUrl = data
        }
      } catch (exception: Exception) {
        plugin.logDebug("Error while handling intent for $data", exception)
      }
    }
    return true
  }

  @MainThread
  suspend fun init() {
    isInitialized = true
    initOpenUrl?.let { uri ->
      handleUri(uri)
    }
    initOpenUrl = null
  }

  @MainThread
  private suspend fun handleUri(uri: Uri) {
    val scheme = uri.scheme ?: return
    val isFile = CONTENT_PROVIDER_SCHEMES.contains(scheme)
    if (isFile) {
      plugin.openFile(copyContentUriAndReturnFileInfo(uri))
    } else {
      plugin.handleOpenUri(uri)
    }
  }

}
