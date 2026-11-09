package com.ppschool.bettercam.engine

import kotlin.math.pow

/**
 * Android re-creations of the Core Image CIPhotoEffect* looks used on iOS
 * (Chrome, Instant, Fade, Process, Transfer, Mono, Noir, Tonal), baked into 33^3 LUTs.
 * They operate on gamma-encoded sRGB like the Apple effects appear to.
 */
object BuiltInLooks {
    private const val N = 33

    private fun interface Look { fun apply(rgb: FloatArray) }

    fun all(): List<FilmSimulation> {
        val identity = FilmSimulation("STD", FilmStyleType.BUILT_IN, bake { }, N, linearInput = false)
        return listOf(
            identity,
            look("CHROME") { c -> contrast(c, 1.12f); saturate(c, 1.35f); warm(c, 0.02f) },
            look("INSTANT") { c ->
                saturate(c, 0.82f); tint(c, 1.06f, 1.02f, 0.86f); fade(c, 0.07f, 0.95f); contrast(c, 0.95f)
            },
            look("FADE") { c -> saturate(c, 0.62f); fade(c, 0.11f, 0.92f); contrast(c, 0.92f) },
            look("PROCESS") { c ->
                contrast(c, 1.1f)
                val l = luma(c)
                val sh = (1f - l).pow(2f)
                c[0] -= 0.06f * sh; c[1] += 0.015f * sh; c[2] += 0.07f * sh
                c[0] += 0.03f * l * l; c[2] -= 0.03f * l * l
                saturate(c, 0.9f)
            },
            look("TRANSFER") { c ->
                tint(c, 1.07f, 1.01f, 0.84f); fade(c, 0.05f, 0.97f); contrast(c, 1.06f); saturate(c, 0.92f)
            },
            look("MONO") { c -> val l = luma601(c); c[0] = l; c[1] = l; c[2] = l },
            look("NOIR") { c ->
                val l = sCurve(luma601(c), 1.6f); c[0] = l; c[1] = l; c[2] = l
            },
            look("TONAL") { c ->
                val l = 0.04f + 0.92f * sCurve(luma601(c), 0.85f); c[0] = l; c[1] = l; c[2] = l
            },
        )
    }

    private fun look(name: String, fn: Look) =
        FilmSimulation(name, FilmStyleType.BUILT_IN, bake(fn), N, linearInput = false)

    private fun bake(fn: Look): FloatArray {
        val out = FloatArray(N * N * N * 3)
        val c = FloatArray(3)
        val m = (N - 1).toFloat()
        var i = 0
        for (b in 0 until N) for (g in 0 until N) for (r in 0 until N) {
            c[0] = r / m; c[1] = g / m; c[2] = b / m
            fn.apply(c)
            out[i++] = c[0].coerceIn(0f, 1f)
            out[i++] = c[1].coerceIn(0f, 1f)
            out[i++] = c[2].coerceIn(0f, 1f)
        }
        return out
    }

    private fun luma(c: FloatArray) = 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2]
    private fun luma601(c: FloatArray) = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2]

    private fun saturate(c: FloatArray, s: Float) {
        val l = luma(c)
        for (i in 0..2) c[i] = l + (c[i] - l) * s
    }

    private fun contrast(c: FloatArray, k: Float) {
        for (i in 0..2) c[i] = (c[i] - 0.5f) * k + 0.5f
    }

    private fun fade(c: FloatArray, black: Float, white: Float) {
        for (i in 0..2) c[i] = black + c[i].coerceIn(0f, 1f) * (white - black)
    }

    private fun tint(c: FloatArray, r: Float, g: Float, b: Float) {
        c[0] *= r; c[1] *= g; c[2] *= b
    }

    private fun warm(c: FloatArray, amount: Float) {
        c[0] += amount; c[2] -= amount
    }

    /** Smooth S-curve around mid grey; k > 1 adds contrast, k < 1 flattens. */
    private fun sCurve(x: Float, k: Float): Float {
        val v = x.coerceIn(0f, 1f)
        return if (v < 0.5f) 0.5f * (2f * v).pow(k) else 1f - 0.5f * (2f * (1f - v)).pow(k)
    }
}
