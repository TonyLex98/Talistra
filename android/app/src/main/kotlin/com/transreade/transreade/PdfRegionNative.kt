package com.talistra.reader

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Rasterizes one rectangle of a PDF page straight into a bitmap of exactly
 * that rectangle's size.
 *
 * The `pdfx` plugin the rest of the app renders with allocates a bitmap of the
 * *whole page at the requested scale* and crops afterwards, so the memory it
 * needs grows with the square of the zoom: a page seen at 8x is a hundred
 * megapixels, which no phone can hold. Here the page is drawn through a matrix
 * into a bitmap the size of the screen, so a page at any zoom costs the same.
 *
 * Calls must come from one thread at a time (MainActivity runs them on a
 * single worker): a [PdfRenderer] opens one page at a time.
 */
class PdfRegionNative {
    private class Open(val descriptor: ParcelFileDescriptor, val renderer: PdfRenderer)

    private val open = HashMap<String, Open>()

    /**
     * JPEG bytes of the [outWidth] x [outHeight] pixel rectangle whose top-left
     * corner is ([left], [top]) in page points, with the page drawn at [scale]
     * pixels per point.
     */
    fun render(
        path: String,
        pageIndex: Int,
        left: Double,
        top: Double,
        outWidth: Int,
        outHeight: Int,
        scale: Double,
        quality: Int,
    ): ByteArray {
        require(outWidth > 0 && outHeight > 0) { "Empty region" }
        val renderer = rendererFor(path)
        val page = renderer.openPage(pageIndex)
        val bitmap = Bitmap.createBitmap(outWidth, outHeight, Bitmap.Config.ARGB_8888)
        try {
            // Opaque paper behind the page: a PDF rarely paints its own.
            bitmap.eraseColor(0xFFFFFFFF.toInt())
            // With a transform the page is placed in points, not stretched to
            // the bitmap, so this is the page scaled and then shifted so that
            // ([left], [top]) lands in the bitmap's corner.
            val matrix = Matrix().apply {
                postScale(scale.toFloat(), scale.toFloat())
                postTranslate((-left * scale).toFloat(), (-top * scale).toFloat())
            }
            page.render(bitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val out = ByteArrayOutputStream(outWidth * outHeight / 8)
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            return out.toByteArray()
        } finally {
            page.close()
            bitmap.recycle()
        }
    }

    private fun rendererFor(path: String): PdfRenderer {
        open[path]?.let { return it.renderer }
        val descriptor = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        return try {
            val renderer = PdfRenderer(descriptor)
            open[path] = Open(descriptor, renderer)
            renderer
        } catch (error: Throwable) {
            descriptor.close()
            throw error
        }
    }

    fun close(path: String) {
        val entry = open.remove(path) ?: return
        try {
            entry.renderer.close()
        } finally {
            entry.descriptor.close()
        }
    }
}
