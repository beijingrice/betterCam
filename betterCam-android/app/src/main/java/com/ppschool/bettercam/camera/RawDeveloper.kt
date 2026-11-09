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
    private val pool = Executors.newFixedThreadPool(max(2, Runtime.getRuntime().availableProcessors() - 1))

    class RawFrame(
        val data: ShortArray,
        val width: Int,
        val height: Int,
        val rowStride: Int, // in pixels
    )

    fun copy(image: Image): RawFrame {
        val plane = image.planes[0]
        val buf = plane.buffer.asShortBuffer()
        val stride = plane.rowStride / 2
        val data = ShortArray(buf.remaining())
        buf.get(data)
        return RawFrame(data, image.width, image.height, stride)
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

        // Super-pixel (half size) development keeps very large sensors manageable.
        val half = frame.width.toLong() * frame.height > 20_000_000L
        val outW = if (half) frame.width / 2 else frame.width
        val outH = if (half) frame.height / 2 else frame.height

        // 1) normalise + shading + WB into a float plane.
        val w = frame.width
        val h = frame.height
        val lin = FloatArray(w * h)
        parallelRows(h) { y0, y1 ->
            for (y in y0 until y1) {
                val row = y * frame.rowStride
                for (x in 0 until w) {
                    val pos = (y and 1) * 2 + (x and 1)
                    val raw = (frame.data[row + x].toInt() and 0xFFFF).toFloat()
                    val black = blackLevels[pos]
                    var v = (raw - black) / (white - black)
                    // WB channel index in RGGB order: R, G_even, G_odd, B
                    val ch = pattern[pos]
                    val wbIdx = when (ch) { 0 -> 0; 2 -> 3; else -> if (rowHasRed(pattern, y)) 1 else 2 }
                    if (shading != null) v *= shadingGain(shading, wbIdx, x, y, w, h)
                    v *= wb[wbIdx]
                    lin[y * w + x] = min(max(v, 0f), 1f)
                }
            }
        }

        // 2) demosaic + matrix + tone.
        val bmp = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val rgb = FloatArray(3)
        parallelRows(outH) { y0, y1 ->
            val px = IntArray(outW)
            val c = FloatArray(3)
            for (y in y0 until y1) {
                for (x in 0 until outW) {
                    if (half) superPixel(lin, w, pattern, x * 2, y * 2, c) else bilinear(lin, w, h, pattern, x, y, c)
                    val r = ccm[0] * c[0] + ccm[1] * c[1] + ccm[2] * c[2]
                    val g = ccm[3] * c[0] + ccm[4] * c[1] + ccm[5] * c[2]
                    val b = ccm[6] * c[0] + ccm[7] * c[1] + ccm[8] * c[2]
                    px[x] = (0xFF shl 24) or (tone(r) shl 16) or (tone(g) shl 8) or tone(b)
                }
                synchronized(bmp) { bmp.setPixels(px, 0, outW, 0, y, outW, 1) }
            }
        }
        rgb.fill(0f)
        return bmp
    }

    private fun rowHasRed(pattern: IntArray, y: Int): Boolean {
        val r = (y and 1) * 2
        return pattern[r] == 0 || pattern[r + 1] == 0
    }

    private fun shadingGain(map: LensShadingMap, ch: Int, x: Int, y: Int, w: Int, h: Int): Float {
        val fx = x.toFloat() / (w - 1) * (map.columnCount - 1)
        val fy = y.toFloat() / (h - 1) * (map.rowCount - 1)
        val x0 = fx.toInt().coerceIn(0, map.columnCount - 1)
        val y0 = fy.toInt().coerceIn(0, map.rowCount - 1)
        val x1 = min(x0 + 1, map.columnCount - 1)
        val y1 = min(y0 + 1, map.rowCount - 1)
        val tx = fx - x0
        val ty = fy - y0
        val a = map.getGainFactor(ch, x0, y0) + (map.getGainFactor(ch, x1, y0) - map.getGainFactor(ch, x0, y0)) * tx
        val b = map.getGainFactor(ch, x0, y1) + (map.getGainFactor(ch, x1, y1) - map.getGainFactor(ch, x0, y1)) * tx
        return a + (b - a) * ty
    }

    private fun superPixel(lin: FloatArray, w: Int, pattern: IntArray, x: Int, y: Int, out: FloatArray) {
        out[0] = 0f; out[1] = 0f; out[2] = 0f
        for (i in 0..3) {
            val v = lin[(y + i / 2) * w + x + (i and 1)]
            when (pattern[i]) { 0 -> out[0] += v; 2 -> out[2] += v; else -> out[1] += v * 0.5f }
        }
    }

    private fun bilinear(lin: FloatArray, w: Int, h: Int, pattern: IntArray, x: Int, y: Int, out: FloatArray) {
        fun at(xx: Int, yy: Int): Float {
            val cx = if (xx < 0) 1 else if (xx >= w) w - 2 else xx
            val cy = if (yy < 0) 1 else if (yy >= h) h - 2 else yy
            return lin[cy * w + cx]
        }
        val ch = pattern[(y and 1) * 2 + (x and 1)]
        val center = lin[y * w + x]
        val cross = (at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1)) * 0.25f
        val diag = (at(x - 1, y - 1) + at(x + 1, y - 1) + at(x - 1, y + 1) + at(x + 1, y + 1)) * 0.25f
        when (ch) {
            0 -> { out[0] = center; out[1] = cross; out[2] = diag }
            2 -> { out[2] = center; out[1] = cross; out[0] = diag }
            else -> {
                val horiz = (at(x - 1, y) + at(x + 1, y)) * 0.5f
                val vert = (at(x, y - 1) + at(x, y + 1)) * 0.5f
                val leftCh = pattern[(y and 1) * 2 + ((x + 1) and 1)]
                out[1] = center
                if (leftCh == 0) { out[0] = horiz; out[2] = vert } else { out[2] = horiz; out[0] = vert }
            }
        }
    }

    private fun tone(linear: Float): Int {
        var v = ColorMath.linearToSrgb(linear)
        v += (v * v * (3f - 2f * v) - v) * 0.25f
        return (v * 255f + 0.5f).toInt().coerceIn(0, 255)
    }

    private fun parallelRows(rows: Int, block: (Int, Int) -> Unit) {
        val chunk = 64
        val tasks = (0 until rows step chunk).map { y0 -> Callable { block(y0, min(rows, y0 + chunk)) } }
        pool.invokeAll(tasks).forEach { it.get() }
    }
}
