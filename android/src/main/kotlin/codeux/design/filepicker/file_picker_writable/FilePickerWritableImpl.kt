package codeux.design.filepicker.file_picker_writable

import android.app.Activity
import android.app.Activity.RESULT_OK
import android.content.ActivityNotFoundException
import android.content.ContentProvider
import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.lang.IllegalStateException

interface ActivityProvider {
  val activity: Activity?
  fun logDebug(message: String, e: Throwable? = null)
  fun openFile(fileInfo: Map<String, String>)
}

class FilePickerWritableImpl(
  private val plugin: ActivityProvider
) : PluginRegistry.ActivityResultListener, PluginRegistry.NewIntentListener {

  companion object {
    const val REQUEST_CODE_OPEN_FILE = 40832
    const val REQUEST_CODE_CREATE_FILE = 40833
  }

  private var filePickerCreateFile: File? = null
  private var filePickerResult: MethodChannel.Result? = null

  private var isInitialized = false
  private var initOpenUrl: Uri? = null


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
    if (!arrayOf(REQUEST_CODE_OPEN_FILE, REQUEST_CODE_CREATE_FILE).contains(
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
    try {
      return when (requestCode) {
        REQUEST_CODE_OPEN_FILE -> {
          val fileUri = data?.data
          if (fileUri != null) {
            plugin.logDebug("Got result $fileUri")
            handleFileUriResponse(result, fileUri)
          } else {
            plugin.logDebug("Got RESULT_OK with null fileUri?")
            result.success(null)
          }
          true
        }
        REQUEST_CODE_CREATE_FILE -> {
          val initialFileContent = filePickerCreateFile
            ?: throw FilePickerException("illegal state - filePickerCreateFile was nul")
          val fileUri =
            requireNotNull(data?.data) { "RESULT_OK with null file uri $data" }
          plugin.logDebug("Got result $fileUri")
          handleFileUriCreateResponse(
            result,
            fileUri,
            initialFileContent
          )

          true
        }
        else -> {
          // can never happen, we already checked the result code.
          throw IllegalStateException("Unexpected requestCode $requestCode")
        }
      }
    } catch (e: Exception) {
      plugin.logDebug("Error during handling file packer result.", e)
      result.error(
        "FatalError",
        "Error handling file picker callback. $e",
        null
      )
      return true
    }
  }

  private fun handleFileUriCreateResponse(
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

  private fun handleFileUriResponse(
    result: MethodChannel.Result,
    fileUri: Uri
  ) {
    copyContentUriAndReturn(result, fileUri)
  }

  fun readFileWithIdentifier(
    result: MethodChannel.Result,
    identifier: String
  ) {
    copyContentUriAndReturn(result, Uri.parse(identifier))
  }

  private fun copyContentUriAndReturn(
    result: MethodChannel.Result,
    fileUri: Uri
  ) {

    result.success(
      copyContentUriAndReturnFileInfo(fileUri)
    )
  }

  private fun copyContentUriAndReturnFileInfo(fileUri: Uri): Map<String, String> {
    val activity = requireActivity()

    val contentResolver = activity.applicationContext.contentResolver
    val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or
      Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    contentResolver.takePersistableUriPermission(fileUri, takeFlags)

    val fileName = readFileInfo(fileUri, contentResolver)

    val tempFile = File.createTempFile(fileName, null, activity.cacheDir)
    plugin.logDebug("Copy file $fileUri to $tempFile")
    contentResolver.openInputStream(fileUri).use { input ->
      requireNotNull(input)
      tempFile.outputStream().use { output ->
        input.copyTo(output)
      }
    }
    return mapOf(
      "path" to tempFile.absolutePath,
      "identifier" to fileUri.toString(),
      "fileName" to fileName,
      "uri" to fileUri.toString()
    )
  }

  private fun readFileInfo(
    uri: Uri,
    contentResolver: ContentResolver
  ): String {

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
      plugin.logDebug("Display Name: $displayName")
      return displayName

    } ?: throw FilePickerException("Unable to load file info from $uri")

  }

  fun onDetachedFromActivity(binding: ActivityPluginBinding) {
    binding.removeActivityResultListener(this)
  }

  fun onAttachedToActivity(binding: ActivityPluginBinding) {
    binding.addActivityResultListener(this)
    binding.addOnNewIntentListener(this)
    onNewIntent(binding.activity.intent)
  }

  fun writeFileWithIdentifier(
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
    contentResolver.openOutputStream(fileUri, "w").use { output ->
      require(output != null)
      file.inputStream().use { input ->
        input.copyTo(output)
      }
    }
    copyContentUriAndReturn(result, fileUri)
  }

  private fun requireActivity() = (plugin.activity
    ?: throw FilePickerException("Illegal state, expected activity to be there."))

  val CONTENT_PROVIDER_SCHEMES = setOf(
    ContentResolver.SCHEME_CONTENT,
    ContentResolver.SCHEME_FILE,
    ContentResolver.SCHEME_ANDROID_RESOURCE
  );

  override fun onNewIntent(intent: Intent?): Boolean {
    val data = intent?.data
    val scheme = data?.scheme

    plugin.logDebug("onNewIntent($data)")
    if (data == null) {
      return false
    }
    if (scheme == null || !CONTENT_PROVIDER_SCHEMES.contains(scheme)) {
      plugin.logDebug("Not handling url $data (no supported scheme $CONTENT_PROVIDER_SCHEMES)")
      return false
    }
    if (isInitialized) {
      plugin.openFile(copyContentUriAndReturnFileInfo(data))
    } else {
      initOpenUrl = data
    }
    return true
  }

  fun init() {
    isInitialized = true
    initOpenUrl?.let { uri ->
      plugin.openFile(copyContentUriAndReturnFileInfo(uri))
    }
    initOpenUrl = null
  }

}