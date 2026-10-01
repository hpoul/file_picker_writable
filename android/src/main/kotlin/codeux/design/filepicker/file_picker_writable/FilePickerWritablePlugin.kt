package codeux.design.filepicker.file_picker_writable

import android.app.Activity
import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.annotation.MainThread
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.StandardMethodCodec
import kotlinx.coroutines.*
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.util.*

private const val TAG = "FilePickerWritable"

/** FilePickerWritablePlugin */
class FilePickerWritablePlugin : FlutterPlugin, MethodCallHandler,
  ActivityAware,
  ContextProvider, CoroutineScope by MainScope() {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel: MethodChannel
  private val impl: FilePickerWritableImpl = FilePickerWritableImpl(this)
  private var currentBinding: ActivityPluginBinding? = null

  override var applicationContext: Context? = null

  private val eventQueue = LinkedList<Map<String, String>>()
  private var eventSink: EventChannel.EventSink? = null

  override fun onAttachedToEngine(
    @NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding
  ) {
    initializePlugin(flutterPluginBinding)
  }

  private fun initializePlugin(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    applicationContext = flutterPluginBinding.applicationContext
    val messenger = flutterPluginBinding.binaryMessenger
    // One shared concurrent queue for every control verb: a serial queue
    // would stall control behind a slow provider call.
    val taskQueue = messenger.makeBackgroundTaskQueue(
      BinaryMessenger.TaskQueueOptions().setIsSerial(false)
    )
    channel = MethodChannel(
      messenger,
      "design.codeux.file_picker_writable",
      StandardMethodCodec.INSTANCE,
      taskQueue
    )
    channel.setMethodCallHandler(this)
    EventChannel(
      flutterPluginBinding.binaryMessenger,
      "design.codeux.file_picker_writable/events"
    ).setStreamHandler(object :
      EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        launch(Dispatchers.Main) {
          while (true) {
            val event = eventQueue.poll() ?: break
            eventSink?.success(event)
          }
        }
      }

      override fun onCancel(arguments: Any?) {
        eventSink = null
      }
    })
  }

  // Runs on the shared concurrent TaskQueue, so there is no ordering across
  // in-flight calls: callers sequence by awaiting. Every `impl` field is
  // touched on the main hop only, so the verbs that touch one (the pickers,
  // and `init` with the launch URLs) hop to main; the rest do their
  // blocking work right here.
  override fun onMethodCall(
    @NonNull call: MethodCall,
    @NonNull result: Result
  ) {
    logDebug("Got method call: ${call.method}")
    when (call.method) {
      // Must stay on main (review-4 F3). No unit test pins this dispatch;
      // LaunchUrlGate's main-thread check throws at runtime if it moves.
      "init" -> onMain(call, result, ::legacyError) {
        impl.init()
        result.success(null)
      }
      "openFilePicker" -> onMain(call, result, ::legacyError) {
        impl.openFilePicker(result)
      }
      "openFilePickerForCreate" -> onMain(call, result, ::legacyError) {
        impl.openFilePickerForCreate(result, call.requireArgument("path"))
      }
      "openDirectory" -> onMain(call, result, Result::taxonomyError) {
        impl.openDirectory(result)
      }
      "readFileWithIdentifier" -> onQueue(call, result, ::legacyError) {
        impl.readFileWithIdentifier(result, call.requireArgument("identifier"))
      }
      "writeFileWithIdentifier" -> onQueue(call, result, ::legacyError) {
        impl.writeFileWithIdentifier(
          result,
          call.requireArgument("identifier"),
          File(call.requireArgument<String>("path"))
        )
      }
      "disposeIdentifier" -> onQueue(call, result, ::legacyError) {
        impl.disposeIdentifier(call.requireArgument("identifier"))
        result.success(null)
      }
      "disposeAllIdentifiers" -> onQueue(call, result, ::legacyError) {
        impl.disposeAllIdentifiers()
        result.success(null)
      }
      "acquire" -> onQueue(call, result, Result::taxonomyError) {
        result.success(
          impl.acquire(
            call.requireArgument("identifier"),
            call.requireArgument("session")
          )
        )
      }
      "release" -> onQueue(call, result, Result::taxonomyError) {
        impl.release(call.requireArgument("id"))
        result.success(null)
      }
      "listChildren" -> onQueue(call, result, Result::taxonomyError) {
        result.success(impl.listChildren(call.requireArgument("identifier")))
      }
      "lookupChild" -> onQueue(call, result, Result::taxonomyError) {
        result.success(
          impl.lookupChild(call.requireArgument("identifier"), call.requireArgument("name"))
        )
      }
      "openRead" -> onQueue(call, result, Result::taxonomyError) {
        result.success(impl.openRead(call.requireArgument("scope")))
      }
      "createDirectory" -> onQueue(call, result, Result::taxonomyError) {
        result.success(
          impl.createDirectory(call.requireArgument("scope"), call.requireArgument("name"))
        )
      }
      "deleteEntry" -> onQueue(call, result, Result::taxonomyError) {
        impl.deleteEntry(call.requireArgument("identifier"), call.requireArgument("recursive"))
        result.success(null)
      }
      "moveEntry" -> onQueue(call, result, Result::taxonomyError) {
        result.success(
          impl.moveEntry(
            call.requireArgument("identifier"),
            call.requireArgument("sourceParent"),
            call.requireArgument("newParent"),
            call.argument("newName")
          )
        )
      }
      else -> result.notImplemented()
    }
  }

  private fun onMain(
    call: MethodCall,
    result: Result,
    reportError: (Result, Exception) -> Unit,
    block: suspend () -> Unit
  ) {
    launch(Dispatchers.Main) {
      try {
        block()
      } catch (e: Exception) {
        logDebug("Error while handling method call $call", e)
        reportError(result, e)
      }
    }
  }

  private fun onQueue(
    call: MethodCall,
    result: Result,
    reportError: (Result, Exception) -> Unit,
    block: () -> Unit
  ) {
    try {
      block()
    } catch (e: Exception) {
      logDebug("Error while handling method call $call", e)
      reportError(result, e)
    }
  }

  /** The error shape of the verbs that predate the taxonomy. */
  private fun legacyError(result: Result, e: Exception) {
    result.error("FilePickerError", e.toString(), null)
  }

  private fun <T> MethodCall.requireArgument(name: String): T =
    argument<T>(name) ?: throw FilePickerException("Expected argument '$name'")

  override fun onDetachedFromEngine(
    @NonNull binding: FlutterPlugin.FlutterPluginBinding
  ) {
    channel.setMethodCallHandler(null)
    impl.onDetachedFromEngine()
    cancel("onDetachedFromEngine")
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
    val exception = e?.let {
      "${e.localizedMessage}\n" +
        StringWriter().also {
          e.printStackTrace(PrintWriter(it))
        }.toString()
    } ?: ""
    sendEvent(
      mapOf(
        "type" to "log",
        "level" to "debug",
        "message" to "${Thread.currentThread().name} $message",
        "exception" to exception
      )
    )
  }

  override fun logWarning(message: String) {
    Log.w(TAG, message)
    sendEvent(
      mapOf(
        "type" to "log",
        "level" to "warning",
        "message" to "${Thread.currentThread().name} $message",
        "exception" to ""
      )
    )
  }

  @MainThread
  override fun openFile(fileInfo: Map<String, String>) {
    channel.invokeMethod("openFile", fileInfo)
  }

  @MainThread
  override fun handleOpenUri(uri: Uri) {
    channel.invokeMethod("handleUri", uri.toString())
  }

  @MainThread
  override fun handleDrop(files: List<Map<String, String>>) {
    channel.invokeMethod("handleDrop", mapOf("files" to files))
  }

  @MainThread
  override fun dragEntered() {
    channel.invokeMethod("dragEntered", null)
  }

  @MainThread
  override fun dragExited() {
    channel.invokeMethod("dragExited", null)
  }

  @MainThread
  override fun sendError(message: String) {
    channel.invokeMethod("handleError", mapOf("message" to message))
  }

  private fun sendEvent(event: Map<String, String>) {
    launch(Dispatchers.Main) {
      eventSink?.success(event) ?: eventQueue.add(event)
    }
  }
}
