package com.ppschool.bettercam.engine

import android.graphics.Bitmap
import com.ppschool.bettercam.data.ExposureMode
import java.nio.ByteBuffer
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sqrt

/**
 * CPU port of the Waveform.metal / Histogram.metal kernels plus the manual-mode light meter.
 * Works on small (128x96) RGBA frames read back from the preview renderer.
 */
class ExposureAnalyzer {
    val overlayWidth = 128
    val overlayHeight = 64
    private val histogramSmoothing = 0.72f
    private val smoothed = FloatArray(256)
    private val counts = IntArray(256)

    fun reset() = smoothed.fill(0f)

    class Result(val image: Bitmap?, val meanLinear: Float)

    fun analyze(buf: ByteBuffer, w: Int, h: Int, mode: ExposureMode): Result {
        var linSum = 0.0
        counts.fill(0)
        val colSum = FloatArray(w)
        for (y in 0 until h) {
            val row = y * w * 4
            for (x in 0 until w) {
                val i = row + x * 4
                val r = buf.get(i).toInt() and 0xFF
                val g = buf.get(i + 1).toInt() and 0xFF
                val b = buf.get(i + 2).toInt() and 0xFF
                val l601 = (0.299f * r + 0.587f * g + 0.114f * b)
                counts[l601.toInt().coerceIn(0, 255)]++
                colSum[x] += (0.2126f * r + 0.7152f * g + 0.0722f * b) / 255f
                linSum += 0.2126 * ColorMath.toLinear[r] + 0.7152 * ColorMath.toLinear[g] + 0.0722 * ColorMath.toLinear[b]
            }
        }
        val mean = (linSum / (w * h)).toFloat()
        val image = when (mode) {
            ExposureMode.WAVEFORM -> waveform(colSum, h, w)
            ExposureMode.HISTOGRAM -> histogram()
            ExposureMode.OFF -> null
        }
        return Result(image, mean)
    }

    private fun waveform(colSum: FloatArray, h: Int, w: Int): Bitmap {
        val px = IntArray(overlayWidth * overlayHeight)
        for (x in 0 until overlayWidth) {
            val src = (x * w / overlayWidth).coerceIn(0, w - 1)
            val avg = (colSum[src] / h).coerceIn(0f, 1f)
            val ty = ((1f - avg) * (overlayHeight - 1)).toInt()
            px[ty * overlayWidth + x] = argb(0.9f)
            if (ty - 1 >= 0) px[(ty - 1) * overlayWidth + x] = argb(0.28f)
            if (ty + 1 < overlayHeight) px[(ty + 1) * overlayWidth + x] = argb(0.28f)
        }
        return Bitmap.createBitmap(px, overlayWidth, overlayHeight, Bitmap.Config.ARGB_8888)
    }

    private fun histogram(): Bitmap {
        var maxCount = 1f
        for (i in 0 until 256) {
            smoothed[i] = smoothed[i] * histogramSmoothing + counts[i] * (1f - histogramSmoothing)
            maxCount = max(maxCount, sqrt(smoothed[i]))
        }
        val px = IntArray(overlayWidth * overlayHeight)
        val white = argb(1f)
        for (x in 0 until overlayWidth) {
            val c = (smoothed[x * 2] + smoothed[x * 2 + 1]) / 2f
            val bar = (sqrt(c) / maxCount * overlayHeight).toInt().coerceIn(0, overlayHeight)
            for (y in overlayHeight - bar until overlayHeight) px[y * overlayWidth + x] = white
        }
        return Bitmap.createBitmap(px, overlayWidth, overlayHeight, Bitmap.Config.ARGB_8888)
    }

    private fun argb(a: Float): Int = ((a * 255).toInt() shl 24) or 0xFFFFFF

    companion object {
        /** Exposure offset in stops relative to 18% grey (iOS exposureTargetOffset analogue). */
        fun offsetStops(meanLinear: Float): Float =
            (ln(max(meanLinear, 1e-4f) / 0.18f) / ln(2f)).coerceIn(-8f, 8f)
    }
}
