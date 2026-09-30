package dev.bench.chanbench

import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

const val SIZE: Long = 1L shl 30

/** Static entry point for the package:jni transport (D). */
object BenchReader {
    // Keep the ParcelFileDescriptor itself alive: its finalizer closes the
    // dup'd fd, which showed up as "pread64 interrupted by close()" then EBADF.
    private val pfds = HashMap<Int, ParcelFileDescriptor>()

    @JvmStatic
    fun read(fd: Int, pos: Long, len: Int): ByteArray {
        val fdObj: FileDescriptor = synchronized(pfds) {
            pfds.getOrPut(fd) { ParcelFileDescriptor.fromFd(fd) }
        }.fileDescriptor
        val buf = ByteArray(len)
        var off = 0
        while (off < len) {
            val n = Os.pread(fdObj, buf, off, len - off, pos + off)
            if (n <= 0) break
            off += n
        }
        return buf
    }
}

class MainActivity : FlutterActivity() {
    private lateinit var file: File
    private lateinit var raf: RandomAccessFile
    private lateinit var chan: FileChannel
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val messenger = engine.dartExecutor.binaryMessenger

        // A: default MethodChannel, handler on the platform thread.
        MethodChannel(messenger, "bench/main").setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    file = File(filesDir, "bench.bin")
                    if (file.length() != SIZE) writeFile(file)
                    raf = RandomAccessFile(file, "r")
                    chan = raf.channel
                    result.success(
                        mapOf(
                            "path" to file.path,
                            "size" to file.length(),
                            "sdk" to Build.VERSION.SDK_INT,
                            "model" to Build.MODEL,
                            "abi" to Build.SUPPORTED_ABIS[0],
                        )
                    )
                }
                "openFd" -> result.success(
                    ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).detachFd()
                )
                "ping" -> result.success(null)
                // A2: blocking read on the platform thread.
                "readSync" -> {
                    val (pos, len) = args(call.arguments)
                    result.success(readAt(pos, len))
                }
                // A1: read on Dispatchers.IO, reply on main.
                "readIO" -> {
                    val (pos, len) = args(call.arguments)
                    scope.launch {
                        val bytes = withContext(Dispatchers.IO) { readAt(pos, len) }
                        result.success(bytes)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // B: MethodChannel on a background TaskQueue; blocking read in the handler.
        val taskQueue = messenger.makeBackgroundTaskQueue()
        MethodChannel(messenger, "bench/bg", StandardMethodCodec.INSTANCE, taskQueue)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ping" -> result.success(null)
                    "read" -> {
                        val (pos, len) = args(call.arguments)
                        result.success(readAt(pos, len))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun args(a: Any?): Pair<Long, Int> {
        val m = a as Map<*, *>
        return Pair((m["pos"] as Number).toLong(), (m["len"] as Number).toInt())
    }

    /** Positional FileChannel.read (pread) of exactly len bytes at pos. Thread-safe. */
    private fun readAt(pos: Long, len: Int): ByteArray {
        val buf = ByteArray(len)
        val bb = ByteBuffer.wrap(buf)
        var p = pos
        while (bb.hasRemaining()) {
            val n = chan.read(bb, p)
            if (n < 0) break
            p += n
        }
        return buf
    }

    private fun writeFile(f: File) {
        val rnd = Random(42)
        val buf = ByteArray(4 shl 20)
        FileOutputStream(f).use { out ->
            var written = 0L
            while (written < SIZE) {
                rnd.nextBytes(buf)
                out.write(buf)
                written += buf.size
            }
            out.fd.sync()
        }
    }
}
