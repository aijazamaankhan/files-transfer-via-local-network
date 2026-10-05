package com.lanbeam.lanbeam

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Native bridge for things Flutter/Dart cannot do directly on Android:
 *  - Storage Access Framework: pick files/folders and stream them by offset
 *    without copying them into the app cache first (multi-GB friendly).
 *  - Wi-Fi multicast lock for UDP discovery.
 *  - Foreground service so transfers survive the screen turning off.
 *  - Media scanning so received photos/videos appear in the gallery.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.lanbeam/android"
    private val io = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())

    private var multicastLock: WifiManager.MulticastLock? = null
    private var pendingPick: MethodChannel.Result? = null
    private var pendingPickKind = 0
    private var pendingPermission: MethodChannel.Result? = null

    private class OpenFile(val pfd: ParcelFileDescriptor, val channel: FileChannel)
    private val openFiles = ConcurrentHashMap<Int, OpenFile>()
    private val nextHandle = AtomicInteger(1)

    companion object {
        private const val PICK_FILES = 4101
        private const val PICK_TREE = 4102
        private const val REQUEST_STORAGE = 4103
        private const val MAX_TREE_ENTRIES = 100000
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> result.success(
                mapOf(
                    "model" to Build.MODEL,
                    "manufacturer" to Build.MANUFACTURER,
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "isTablet" to (resources.configuration.smallestScreenWidthDp >= 600),
                )
            )
            "downloadsDirectory" -> result.success(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
            )
            "acquireMulticastLock" -> {
                if (multicastLock == null) {
                    val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                    multicastLock = wifi.createMulticastLock("lanbeam-discovery").apply {
                        setReferenceCounted(false)
                        acquire()
                    }
                }
                result.success(true)
            }
            "releaseMulticastLock" -> {
                multicastLock?.let { if (it.isHeld) it.release() }
                multicastLock = null
                result.success(true)
            }
            "startTransferService" -> {
                val intent = Intent(this, TransferForegroundService::class.java)
                    .putExtra("title", call.argument<String>("title") ?: "Transferring files")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
                result.success(true)
            }
            "stopTransferService" -> {
                stopService(Intent(this, TransferForegroundService::class.java))
                result.success(true)
            }
            "requestLegacyStorage" -> {
                // Only Android 9 (API 28) and 10 (API 29) need this to write
                // into Download/; newer versions need no storage permission.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                    Build.VERSION.SDK_INT > Build.VERSION_CODES.Q ||
                    checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(true)
                } else if (pendingPermission != null) {
                    result.error("busy", "Permission request in progress", null)
                } else {
                    pendingPermission = result
                    requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQUEST_STORAGE)
                }
            }
            "openAppSettings" -> {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                result.success(true)
            }
            "pickFiles" -> startPick(PICK_FILES, result)
            "pickTree" -> startPick(PICK_TREE, result)
            "open" -> background(result) {
                val uri = Uri.parse(call.argument<String>("uri"))
                val pfd = contentResolver.openFileDescriptor(uri, "r")
                    ?: throw IllegalStateException("Cannot open $uri")
                val handle = nextHandle.getAndIncrement()
                openFiles[handle] = OpenFile(pfd, FileInputStream(pfd.fileDescriptor).channel)
                handle
            }
            "read" -> background(result) {
                val file = openFiles[call.argument<Int>("handle")!!]
                    ?: throw IllegalStateException("Invalid handle")
                val offset = (call.argument<Number>("offset")!!).toLong()
                val length = call.argument<Int>("length")!!
                val buffer = ByteBuffer.allocate(length)
                var total = 0
                while (total < length) {
                    val n = file.channel.read(buffer, offset + total)
                    if (n <= 0) break
                    total += n
                }
                buffer.array().copyOf(total)
            }
            "close" -> background(result) {
                openFiles.remove(call.argument<Int>("handle")!!)?.let {
                    it.channel.close()
                    it.pfd.close()
                }
                true
            }
            "stat" -> background(result) { stat(Uri.parse(call.argument<String>("uri"))) }
            "scanMedia" -> {
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                MediaScannerConnection.scanFile(applicationContext, paths.toTypedArray(), null, null)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: SecurityException) {
                main.post { result.error("permission_denied", e.message, null) }
            } catch (e: java.io.FileNotFoundException) {
                main.post { result.error("not_found", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("io_error", e.message, null) }
            }
        }
    }

    private fun startPick(kind: Int, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A picker is already open", null)
            return
        }
        val intent = if (kind == PICK_FILES) {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        }
        pendingPick = result
        pendingPickKind = kind
        @Suppress("DEPRECATION")
        startActivityForResult(intent, kind)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_STORAGE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermission?.success(granted)
            pendingPermission = null
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_FILES && requestCode != PICK_TREE) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick ?: return
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return
        }
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (requestCode == PICK_FILES) {
            val uris = mutableListOf<Uri>()
            data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) }
            if (uris.isEmpty()) data.data?.let { uris.add(it) }
            background(result) {
                uris.map { uri ->
                    // Persist access so an interrupted transfer can resume after restart.
                    try { contentResolver.takePersistableUriPermission(uri, flags) } catch (_: Exception) {}
                    stat(uri) + mapOf("uri" to uri.toString())
                }
            }
        } else {
            val tree = data.data ?: run { result.success(null); return }
            try { contentResolver.takePersistableUriPermission(tree, flags) } catch (_: Exception) {}
            background(result) { listTree(tree) }
        }
    }

    private fun stat(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size: Long = -1
        var modified: Long? = null
        val projection = arrayOf(
            OpenableColumns.DISPLAY_NAME,
            OpenableColumns.SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        contentResolver.query(uri, projection, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                name = c.getString(0)
                if (!c.isNull(1)) size = c.getLong(1)
                val mi = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                if (mi >= 0 && !c.isNull(mi)) modified = c.getLong(mi)
            }
        }
        if (size < 0) {
            contentResolver.openFileDescriptor(uri, "r")?.use { size = it.statSize }
        }
        return mapOf(
            "name" to (name ?: uri.lastPathSegment ?: "file"),
            "size" to size,
            "modified" to modified,
            "mime" to contentResolver.getType(uri),
        )
    }

    /** Recursively lists a document tree (iterative, bounded). */
    private fun listTree(tree: Uri): Map<String, Any?> {
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val rootDoc = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
        val rootName = stat(rootDoc)["name"] as String
        val entries = mutableListOf<Map<String, Any?>>()
        val stack = ArrayDeque<Pair<String, String>>() // documentId, relative path
        stack.add(rootId to "")
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        while (stack.isNotEmpty() && entries.size < MAX_TREE_ENTRIES) {
            val (docId, prefix) = stack.removeLast()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            contentResolver.query(children, projection, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    val name = c.getString(1)
                    val mime = c.getString(2)
                    val path = if (prefix.isEmpty()) name else "$prefix/$name"
                    if (name == null) {
                        // Skip unnamed documents.
                    } else if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        stack.add(id to path)
                    } else {
                        entries.add(
                            mapOf(
                                "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                                "path" to path,
                                "size" to (if (c.isNull(3)) 0L else c.getLong(3)),
                                "modified" to (if (c.isNull(4)) null else c.getLong(4)),
                                "mime" to mime,
                            )
                        )
                    }
                }
            }
        }
        return mapOf("rootName" to rootName, "entries" to entries)
    }

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        openFiles.values.forEach {
            try { it.channel.close(); it.pfd.close() } catch (_: Exception) {}
        }
        openFiles.clear()
        io.shutdown()
        super.onDestroy()
    }
}
