package com.ppschool.bettercam.camera

import android.graphics.Bitmap
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.params.LensShadingMap
import android.media.Image
import com.ppschool.bettercam.engine.ColorMath
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * Minimal Bayer RAW development for the "ZERO PROCESSING" mode
 * (Android stand-in for CIRAWFilter): black/white level, lens shading, white balance,
 * bilinear demosaic, camera->sRGB matrix and a gentle tone curve. No sharpening, no NR.
 */
object RawDeveloper {
    private val pool = Executors.newFixedThreadPool(
        max(2, Runtime.getRuntime().availableProcessors() / 2), BackgroundThreads.factory("bettercam.raw")
    )

    /** Tightly packed RAW16 pixels (row stride == width), detached from the camera's Image. */
    class RawFrame(
        val data: ShortArray,
        val width: Int,
        val height: Int,
    ) {
        val rowStride: Int get() = width

        /** Little-endian RAW16 bytes, the layout DngCreator.writeByteBuffer expects. */
        fun toByteBuffer(): java.nio.ByteBuffer {
            val buf = java.nio.ByteBuffer.allocateDirect(data.size * 2).order(java.nio.ByteOrder.nativeOrder())
            buf.asShortBuffer().put(data)
            return buf
        }
    }

    fun copy(image: Image): RawFrame {
        val plane = image.planes[0]
        val w = image.width
        val h = image.height
        val src = plane.buffer.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer()
        val stride = plane.rowStride / 2
        val data = ShortArray(w * h)
        if (stride == w) {
            src.get(data, 0, w * h)
        } else {
            for (y in 0 until h) {
                src.position(y * stride)
                src.get(data, y * w, w)
            }
        }
        return RawFrame(data, w, h)
    }

    fun develop(frame: RawFrame, chars: CameraCharacteristics, result: CaptureResult): Bitmap? {
        val cfa = chars.get(CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT) ?: return null
        // channel per 2x2 position: 0=R 1=G 2=B
        val pattern = when (cfa) {
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_RGGB -> intArrayOf(0, 1, 1, 2)
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GRBG -> intArrayOf(1, 0, 2, 1)
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GBRG -> intArrayOf(1, 2, 0, 1)
            CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_BGGR -> intArrayOf(2, 1, 1, 0)
            else -> return null
        }
        val blackLevels = result.get(CaptureResult.SENSOR_DYNAMIC_BLACK_LEVEL)
            ?: chars.get(CameraCharacteristics.SENSOR_BLACK_LEVEL_PATTERN)?.let { p ->
                floatArrayOf(p.getOffsetForIndex(0, 0).toFloat(), p.getOffsetForIndex(1, 0).toFloat(),
                    p.getOffsetForIndex(0, 1).toFloat(), p.getOffsetForIndex(1, 1).toFloat())
            } ?: floatArrayOf(64f, 64f, 64f, 64f)
        val white = (result.get(CaptureResult.SENSOR_DYNAMIC_WHITE_LEVEL)
            ?: chars.get(CameraCharacteristics.SENSOR_INFO_WHITE_LEVEL) ?: 1023).toFloat()
        val gainsVec = result.get(CaptureResult.COLOR_CORRECTION_GAINS)
        val wb = floatArrayOf(gainsVec?.red ?: 2f, gainsVec?.greenEven ?: 1f, gainsVec?.greenOdd ?: 1f, gainsVec?.blue ?: 1.6f)
        val ccm = FloatArray(9).also { m ->
            val t = result.get(CaptureResult.COLOR_CORRECTION_TRANSFORM)
            if (t != null) for (i in 0..8) m[i] = t.getElement(i % 3, i / 3).toFloat()
            else { m[0] = 1f; m[4] = 1f; m[8] = 1f }
        }
        val shading = result.get(CaptureResult.STATISTICS_LENS_SHADING_CORRECTION_MAP)
        // The ISP applies this digital gain after the RAW stage; include it so brightness matches the JPEG/AE target.
        val boost = (result.get(CaptureResult.CONTROL_POST_RAW_SENSITIVITY_BOOST) ?: 100) / 100f

        // Super-pixel (half size) development keeps very large sensors manageable.
        val half = frame.width.toLong() * frame.height > 20_000_000L
        val outW = if (half) frame.width / 2 else frame.width
        val outH = if (half) frame.height / 2 else frame.height

        // 1) normalise + shading + WB into a float plane.
        val w = frame.width
        val h = frame.height
        val lin = FloatArray(w * h)
        val grid = shading?.let { ShadingGrid(it) }
        parallelRows(h) { y0, y1 ->
            val rowGain = grid?.newRowBuffer()
            val black = FloatArray(2)
            val scale = FloatArray(2)
            val wbIdx = IntArray(2)
            for (y in y0 until y1) {
                // Per-row constants for the two CFA columns (WB index in RGGB order: R, G_even, G_odd, B).
                for (px in 0..1) {
                    val pos = (y and 1) * 2 + px
                    val idx = when (pattern[pos]) { 0 -> 0; 2 -> 3; else -> if (rowHasRed(pattern, y)) 1 else 2 }
                    wbIdx[px] = idx
                    black[px] = blackLevels[pos]
                    scale[px] = wb[idx] * boost / (white - blackLevels[pos])
                }
                if (grid != null) grid.fillRow(y, h, rowGain!!)
                val src = y * frame.rowStride
                val dst = y * w
                val data = frame.data
                for (x in 0 until w) {
                    val p = x and 1
                    var v = ((data[src + x].toInt() and 0xFFFF) - black[p]) * scale[p]
                    if (grid != null) v *= grid.gain(rowGain!!, wbIdx[p], x, w)
                    lin[dst + x] = if (v < 0f) 0f else if (v > 1f) 1f else v
                }
            }
        }

        // 2) demosaic + matrix + tone.
        val bmp = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val lut = toneLut
        parallelRows(outH) { y0, y1 ->
            val px = IntArray(outW)
            val c = FloatArray(3)
            for (y in y0 until y1) {
                val interiorRow = !half && y > 0 && y < h - 1
                for (x in 0 until outW) {
                    when {
                        half -> superPixel(lin, w, pattern, x * 2, y * 2, c)
                        interiorRow && x > 0 && x < w - 1 -> bilinearInterior(lin, w, pattern, x, y, c)
                        else -> bilinear(lin, w, h, pattern, x, y, c)
                    }
                    val r = ccm[0] * c[0] + ccm[1] * c[1] + ccm[2] * c[2]
                    val g = ccm[3] * c[0] + ccm[4] * c[1] + ccm[5] * c[2]
                    val b = ccm[6] * c[0] + ccm[7] * c[1] + ccm[8] * c[2]
                    px[x] = (0xFF shl 24) or (lut[toneIndex(r)] shl 16) or (lut[toneIndex(g)] shl 8) or lut[toneIndex(b)]
                }
                synchronized(bmp) { bmp.setPixels(px, 0, outW, 0, y, outW, 1) }
            }
        }
        return bmp
    }

    private fun rowHasRed(pattern: IntArray, y: Int): Boolean {
        val r = (y and 1) * 2
        return pattern[r] == 0 || pattern[r + 1] == 0
    }

    /** Lens shading gains copied once into flat arrays (LensShadingMap lookups are slow per pixel). */
    private class ShadingGrid(map: LensShadingMap) {
        val cols = map.columnCount
        val rows = map.rowCount
        private val g = Array(4) { ch -> FloatArray(cols * rows) { i -> map.getGainFactor(ch, i % cols, i / cols) } }

        fun newRowBuffer() = Array(4) { FloatArray(cols) }

        /** Interpolates the grid vertically for image row [y]. */
        fun fillRow(y: Int, h: Int, out: Array<FloatArray>) {
            val fy = y.toFloat() / (h - 1) * (rows - 1)
            val y0 = fy.toInt().coerceIn(0, rows - 1)
            val y1 = min(y0 + 1, rows - 1)
            val t = fy - y0
            for (ch in 0..3) {
                val src = g[ch]; val dst = out[ch]
                for (c in 0 until cols) {
                    val a = src[y0 * cols + c]
                    dst[c] = a + (src[y1 * cols + c] - a) * t
                }
            }
        }

        fun gain(row: Array<FloatArray>, ch: Int, x: Int, w: Int): Float {
            val fx = x.toFloat() / (w - 1) * (cols - 1)
            val x0 = fx.toInt().coerceIn(0, cols - 1)
            val x1 = min(x0 + 1, cols - 1)
            val r = row[ch]
            return r[x0] + (r[x1] - r[x0]) * (fx - x0)
        }
    }

    private fun superPixel(lin: FloatArray, w: Int, pattern: IntArray, x: Int, y: Int, out: FloatArray) {
        out[0] = 0f; out[1] = 0f; out[2] = 0f
        for (i in 0..3) {
            val v = lin[(y + i / 2) * w + x + (i and 1)]
            when (pattern[i]) { 0 -> out[0] += v; 2 -> out[2] += v; else -> out[1] += v * 0.5f }
        }
    }

    private fun bilinearInterior(lin: FloatArray, w: Int, pattern: IntArray, x: Int, y: Int, out: FloatArray) {
        val i = y * w + x
        val center = lin[i]
        val left = lin[i - 1]; val right = lin[i + 1]
        val up = lin[i - w]; val down = lin[i + w]
        val ch = pattern[(y and 1) * 2 + (x and 1)]
        when (ch) {
            0, 2 -> {
                val cross = (left + right + up + down) * 0.25f
                val diag = (lin[i - w - 1] + lin[i - w + 1] + lin[i + w - 1] + lin[i + w + 1]) * 0.25f
                if (ch == 0) { out[0] = center; out[1] = cross; out[2] = diag } else { out[2] = center; out[1] = cross; out[0] = diag }
            }
            else -> {
                val horiz = (left + right) * 0.5f
                val vert = (up + down) * 0.5f
                out[1] = center
                if (pattern[(y and 1) * 2 + ((x + 1) and 1)] == 0) { out[0] = horiz; out[2] = vert } else { out[2] = horiz; out[0] = vert }
            }
        }
    }

    private fun at(lin: FloatArray, w: Int, h: Int, xx: Int, yy: Int): Float {
        val cx = if (xx < 0) 1 else if (xx >= w) w - 2 else xx
        val cy = if (yy < 0) 1 else if (yy >= h) h - 2 else yy
        return lin[cy * w + cx]
    }

    private fun bilinear(lin: FloatArray, w: Int, h: Int, pattern: IntArray, x: Int, y: Int, out: FloatArray) {
        val ch = pattern[(y and 1) * 2 + (x and 1)]
        val center = lin[y * w + x]
        val cross = (at(lin, w, h, x - 1, y) + at(lin, w, h, x + 1, y) + at(lin, w, h, x, y - 1) + at(lin, w, h, x, y + 1)) * 0.25f
        val diag = (at(lin, w, h, x - 1, y - 1) + at(lin, w, h, x + 1, y - 1) + at(lin, w, h, x - 1, y + 1) + at(lin, w, h, x + 1, y + 1)) * 0.25f
        when (ch) {
            0 -> { out[0] = center; out[1] = cross; out[2] = diag }
            2 -> { out[2] = center; out[1] = cross; out[0] = diag }
            else -> {
                val horiz = (at(lin, w, h, x - 1, y) + at(lin, w, h, x + 1, y)) * 0.5f
                val vert = (at(lin, w, h, x, y - 1) + at(lin, w, h, x, y + 1)) * 0.5f
                out[1] = center
                if (pattern[(y and 1) * 2 + ((x + 1) and 1)] == 0) { out[0] = horiz; out[2] = vert } else { out[2] = horiz; out[0] = vert }
            }
        }
    }

    private const val TONE_STEPS = 4096
    /** tone() baked into a table over linear 0..1 (inputs above 1 clip to white). */
    private val toneLut = IntArray(TONE_STEPS + 1) { tone(it / TONE_STEPS.toFloat()) }

    private fun toneIndex(v: Float): Int = if (v <= 0f) 0 else if (v >= 1f) TONE_STEPS else (v * TONE_STEPS + 0.5f).toInt()

    /**
     * Default "camera" tone curve: +~0.5 EV for mid-grey with a soft shoulder that keeps white at 1.0
     * (similar to the baseline curve Apple's RAW engine applies), then sRGB and a light S-curve.
     */
    private fun tone(linear: Float): Int {
        val x = linear.coerceAtLeast(0f)
        val lifted = x * 1.6f / (1f + 0.6f * x)
        var v = ColorMath.linearToSrgb(lifted)
        v += (v * v * (3f - 2f * v) - v) * 0.15f
        return (v * 255f + 0.5f).toInt().coerceIn(0, 255)
    }

    private fun parallelRows(rows: Int, block: (Int, Int) -> Unit) {
        val chunk = 64
        val tasks = (0 until rows step chunk).map { y0 -> Callable { block(y0, min(rows, y0 + chunk)) } }
        pool.invokeAll(tasks).forEach { it.get() }
    }
}
