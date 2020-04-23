package codeux.design.filepicker.file_picker_writable

import android.app.Activity
import android.util.Log
import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.Registrar
import java.io.File
import java.lang.UnsupportedOperationException

/** FilePickerWritablePlugin */
public class FilePickerWritablePlugin : FlutterPlugin, MethodCallHandler,
  ActivityAware,
  ActivityProvider {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel: MethodChannel
  private val impl: FilePickerWritableImpl = FilePickerWritableImpl(this)
  private var currentBinding: ActivityPluginBinding? = null

  override fun onAttachedToEngine(
    @NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding
  ) {
    channel = MethodChannel(
      flutterPluginBinding.getFlutterEngine().getDartExecutor(),
      "design.codeux.file_picker_writable"
    )
    channel.setMethodCallHandler(this);
  }

  // This static function is optional and equivalent to onAttachedToEngine. It supports the old
  // pre-Flutter-1.12 Android projects. You are encouraged to continue supporting
  // plugin registration via this function while apps migrate to use the new Android APIs
  // post-flutter-1.12 via https://flutter.dev/go/android-project-migration.
  //
  // It is encouraged to share logic between onAttachedToEngine and registerWith to keep
  // them functionally equivalent. Only one of onAttachedToEngine or registerWith will be called
  // depending on the user's project. onAttachedToEngine or registerWith must both be defined
  // in the same class.
  companion object {
    const val TAG = "FilePickerWritable"

    @JvmStatic
    fun registerWith(registrar: Registrar) {
      val channel = MethodChannel(
        registrar.messenger(),
        "design.codeux.file_picker_writable"
      )
      channel.setMethodCallHandler(FilePickerWritablePlugin())
      throw UnsupportedOperationException("Right now we only support v2 plugin embedding.")
    }
  }


  override fun onMethodCall(
    @NonNull call: MethodCall,
    @NonNull result: Result
  ) {
    try {
      when (call.method) {
        "openFilePicker" -> {
          impl.openFilePicker(result)
        }
        "openFilePickerForCreate" -> {
          val path = call.argument<String>("path")
            ?: throw FilePickerException("Expected argument 'path'")
          impl.openFilePickerForCreate(result, path)
        }
        "readFileWithIdentifier" -> {
          val identifier = call.argument<String>("identifier")
            ?: throw FilePickerException("Expected argument 'identifier'")
          impl.readFileWithIdentifier(result, identifier)
        }
        "writeFileWithIdentifier" -> {
          val identifier = call.argument<String>("identifier")
            ?: throw FilePickerException("Expected argument 'identifier'")
          val path = call.argument<String>("path")
            ?: throw FilePickerException("Expected argument 'path'")
          impl.writeFileWithIdentifier(result, identifier, File(path))
        }
        else -> {
          result.notImplemented()
        }
      }
    } catch (e: Exception) {
      logDebug("Error while handling method call $call", e)
      result.error("FilePickerError", e.toString(), null)
    }
  }

  override fun onDetachedFromEngine(
    @NonNull binding: FlutterPlugin.FlutterPluginBinding
  ) {
    channel.setMethodCallHandler(null)
  }

  override fun onDetachedFromActivity() {
    currentBinding?.let { impl.onDetachedFromActivity(it) }
    currentBinding = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    currentBinding = binding
    impl.onAttachedToActivity(binding)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    currentBinding = binding
    impl.onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    currentBinding?.let { impl.onDetachedFromActivity(it) }
    currentBinding = null
  }

  override val activity: Activity?
    get() = currentBinding?.activity

  override fun logDebug(message: String, e: Throwable?) {
    Log.d(TAG, message, e)
  }
}
