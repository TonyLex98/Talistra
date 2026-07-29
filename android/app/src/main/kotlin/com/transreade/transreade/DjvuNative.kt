package com.talistra.reader

/**
 * JNI boundary for Talistra's MIT DjVu engine.
 *
 * Flutter never calls this object on the Android main thread: MainActivity
 * dispatches every decode to a small worker pool and only posts the result
 * back to the UI thread.
 */
object DjvuNative {
    init {
        System.loadLibrary("litra_djvu")
    }

    external fun open(path: String): LongArray
    external fun pageInfo(handle: Long, pageIndex: Int): IntArray
    external fun renderPage(
        handle: Long,
        pageIndex: Int,
        width: Int,
        height: Int,
    ): ByteArray
    external fun pageText(handle: Long, pageIndex: Int): String?
    external fun pageWords(handle: Long, pageIndex: Int): String
    external fun close(handle: Long)
}
