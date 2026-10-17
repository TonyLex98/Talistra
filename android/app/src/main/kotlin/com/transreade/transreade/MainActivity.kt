package com.talistra.reader

import android.content.Intent
import android.content.Context
import android.os.BatteryManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Receives documents opened from outside the app — a file manager's "Open
 * with", or the system share sheet — and hands them to Flutter.
 *
 * The document arrives as a `content://` URI owned by another app: Dart
 * can't read that directly, and the permission on it disappears once this
 * task finishes. So it's copied into this app's cache here, under its
 * original display name, and passed on as a plain file path; the library
 * then imports that copy exactly as if the file had been picked from
 * inside the app.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val INCOMING_CHANNEL = "transread/incoming_file"
        const val DJVU_CHANNEL = "litra/djvu"
        const val READING_DISPLAY_CHANNEL = "litra/reading_display"
        const val PDF_REGION_CHANNEL = "litra/pdf_region"
    }

    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val djvuWorkers = Executors.newFixedThreadPool(2)

    /** One thread: a PdfRenderer opens one page at a time (see [PdfRegionNative]). */
    private val pdfWorker = Executors.newSingleThreadExecutor()
    private val pdfRegions = PdfRegionNative()

    /** A file that arrived before Dart was listening. */
    private var pendingPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INCOMING_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Asked once on startup: is anything waiting to be opened?
                    "consumePending" -> {
                        result.success(pendingPath)
                        pendingPath = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DJVU_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_arguments", "Missing DjVu path", null)
                        } else {
                            runDjvu(result) {
                                val info = DjvuNative.open(path)
                                mapOf("handle" to info[0], "pageCount" to info[1])
                            }
                        }
                    }
                    "pageInfo" -> withDjvuPageArguments(call.arguments, result) {
                        handle, page -> runDjvu(result) {
                            val info = DjvuNative.pageInfo(handle, page)
                            mapOf(
                                "width" to info[0],
                                "height" to info[1],
                                "dpi" to info[2],
                            )
                        }
                    }
                    "renderPage" -> withDjvuPageArguments(call.arguments, result) {
                        handle, page ->
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as Map<String, Any?>
                        val width = (args["width"] as? Number)?.toInt()?.coerceIn(1, 2400)
                        val height = (args["height"] as? Number)?.toInt()?.coerceIn(1, 4000)
                        if (width == null || height == null) {
                            result.error("bad_arguments", "Missing DjVu render size", null)
                        } else {
                            runDjvu(result) {
                                DjvuNative.renderPage(handle, page, width, height)
                            }
                        }
                    }
                    "pageText" -> withDjvuPageArguments(call.arguments, result) {
                        handle, page -> runDjvu(result) {
                            DjvuNative.pageText(handle, page)
                        }
                    }
                    "pageWords" -> withDjvuPageArguments(call.arguments, result) {
                        handle, page -> runDjvu(result) {
                            DjvuNative.pageWords(handle, page)
                        }
                    }
                    "close" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as? Map<String, Any?>
                        val handle = (args?.get("handle") as? Number)?.toLong()
                        if (handle == null) {
                            result.error("bad_arguments", "Missing DjVu handle", null)
                        } else {
                            runDjvu(result) {
                                DjvuNative.close(handle)
                                null
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PDF_REGION_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "render" -> {
                        val path = call.argument<String>("path")
                        val page = call.argument<Number>("page")?.toInt()
                        val left = call.argument<Number>("left")?.toDouble()
                        val top = call.argument<Number>("top")?.toDouble()
                        val width = call.argument<Number>("width")?.toInt()
                        val height = call.argument<Number>("height")?.toInt()
                        val scale = call.argument<Number>("scale")?.toDouble()
                        val quality = call.argument<Number>("quality")?.toInt() ?: 92
                        if (path == null || page == null || left == null || top == null ||
                            width == null || height == null || scale == null
                        ) {
                            result.error("bad_arguments", "Missing PDF region argument", null)
                        } else {
                            pdfWorker.execute {
                                try {
                                    val bytes = pdfRegions.render(
                                        path, page, left, top, width, height, scale, quality,
                                    )
                                    mainHandler.post { result.success(bytes) }
                                } catch (error: Throwable) {
                                    val message = error.message ?: error.javaClass.simpleName
                                    mainHandler.post { result.error("pdf_region_error", message, null) }
                                }
                            }
                        }
                    }
                    "close" -> {
                        val path = call.argument<String>("path")
                        pdfWorker.execute {
                            try {
                                if (path != null) pdfRegions.close(path)
                            } catch (error: Throwable) {
                                // Closing is best effort: the file is going away.
                            }
                            mainHandler.post { result.success(null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, READING_DISPLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBrightness" -> {
                        val brightness = (call.argument<Number>("brightness"))?.toFloat()
                        val params = window.attributes
                        params.screenBrightness = brightness?.coerceIn(0.05f, 1.0f)
                            ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        window.attributes = params
                        result.success(null)
                    }
                    "setKeepScreenOn" -> {
                        if (call.argument<Boolean>("enabled") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "batteryPercent" -> {
                        val manager = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        result.success(manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                    }
                    else -> result.notImplemented()
                }
            }
        handleIntent(intent)
    }

    private fun withDjvuPageArguments(
        rawArguments: Any?,
        result: MethodChannel.Result,
        block: (Long, Int) -> Unit,
    ) {
        @Suppress("UNCHECKED_CAST")
        val args = rawArguments as? Map<String, Any?>
        val handle = (args?.get("handle") as? Number)?.toLong()
        val page = (args?.get("page") as? Number)?.toInt()
        if (handle == null || page == null || page < 0) {
            result.error("bad_arguments", "Invalid DjVu document or page", null)
            return
        }
        block(handle, page)
    }

    private fun runDjvu(result: MethodChannel.Result, block: () -> Any?) {
        djvuWorkers.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                val message = error.message ?: error.javaClass.simpleName
                mainHandler.post { result.error("djvu_error", message, null) }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        @Suppress("DEPRECATION")
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        }
        if (uri == null) return
        val path = copyToCache(uri) ?: return
        // Remember it either way: Dart may not have a listener attached yet
        // (cold start), and it asks for anything pending as soon as it does.
        pendingPath = path
        channel?.invokeMethod("openFile", path)
    }

    /**
     * Copies [uri] into the cache under its original display name, so the
     * library keeps the document's real title and file extension.
     */
    private fun copyToCache(uri: Uri): String? {
        return try {
            // A file:// URI that already points inside this app (or anywhere
            // readable without a permission) can be handed over as it is —
            // no copy, and no dependency on a content provider.
            if (uri.scheme == "file") {
                val direct = uri.path?.let(::File)
                if (direct != null && direct.canRead()) return direct.absolutePath
            }
            // Some file managers give us a generic display name such as
            // "document" even though the intent has the correct MIME type.
            // Keep that type in the temporary filename: Flutter deliberately
            // routes readers by extension after the permission-bearing URI
            // has been copied into private storage.
            val name = nameWithExtension(uri)
            val directory = File(cacheDir, "incoming").apply { mkdirs() }
            val file = File(directory, name)
            contentResolver.openInputStream(uri)?.use { input ->
                file.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            file.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) {
                    val name = cursor.getString(index)
                    if (!name.isNullOrBlank()) return name
                }
            }
        } catch (e: Exception) {
            // Some providers don't support querying; the fallback below is fine.
        }
        return uri.lastPathSegment
    }

    private fun nameWithExtension(uri: Uri): String {
        val name = displayName(uri)?.substringAfterLast('/')?.ifBlank { "document" } ?: "document"
        if (name.substringAfterLast('.', "").isNotBlank()) return name
        val mime = contentResolver.getType(uri) ?: return name
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: return name
        return "$name.$extension"
    }
}
