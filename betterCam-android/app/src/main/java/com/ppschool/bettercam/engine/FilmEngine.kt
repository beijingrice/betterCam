package com.ppschool.bettercam.engine

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

enum class FilmStyleType { BUILT_IN, LUT, BUILT_IN_LUT }

/**
 * A film look. Every look is stored as a 3D LUT (RGB triplets, red fastest, then green, then blue).
 * [linearInput] = true mirrors iOS CIColorCube, which is evaluated in Core Image's linear working space.
 */
class FilmSimulation(
    var name: String,
    val type: FilmStyleType,
    val lut: FloatArray,
    val dimension: Int,
    val linearInput: Boolean,
    val fileName: String? = null,
) {
    val id: String = UUID.randomUUID().toString()
}

object FilmEngine {
    private const val TAG = "FilmEngine"
    private const val INDEX_KEY = "UserSavedLUTs"

    private lateinit var appContext: Context
    var availableSimulations by mutableStateOf(listOf<FilmSimulation>())
        private set
    /** Bumped whenever the library changes so GPU caches can be invalidated. */
    var libraryVersion by mutableIntStateOf(0)
        private set

    private val workers = Executors.newFixedThreadPool(
        max(2, Runtime.getRuntime().availableProcessors() / 2),
        com.ppschool.bettercam.camera.BackgroundThreads.factory("bettercam.film")
    )

    fun init(context: Context) {
        if (::appContext.isInitialized) return
        appContext = context.applicationContext
        val builtIns = BuiltInLooks.all()
        val custom = loadSavedCustomLUTs()
        availableSimulations = builtIns + custom
        // The bundled .cube files are ~1 MB each; parse them off the main thread.
        Thread({
            val t0 = System.nanoTime()
            val bundled = loadBundleLUTs(builtIns)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                val imported = availableSimulations.filter { it.type == FilmStyleType.LUT }
                availableSimulations = builtIns + bundled + imported
                libraryVersion++
            }
            Log.i(TAG, "bundled LUTs parsed in ${(System.nanoTime() - t0) / 1_000_000} ms")
        }, "bettercam.luts").start()
    }

    fun simulation(named: String): FilmSimulation? = availableSimulations.firstOrNull { it.name == named }

    // ---------------------------------------------------------------- library

    private fun loadBundleLUTs(existing: List<FilmSimulation>): List<FilmSimulation> {
        val out = mutableListOf<FilmSimulation>()
        val files = appContext.assets.list("luts") ?: return out
        for (file in files.sorted()) {
            if (!file.endsWith(".cube", true)) continue
            val parsed = appContext.assets.open("luts/$file").use { parseCube(it) } ?: continue
            val name = file.substringBeforeLast('.').uppercase()
            if (existing.none { it.name == name } && out.none { it.name == name }) {
                out += FilmSimulation(name, FilmStyleType.BUILT_IN_LUT, parsed.first, parsed.second, linearInput = true)
            }
        }
        return out
    }

    /** Parses an Adobe/Resolve .cube 3D LUT. Returns (RGB float data, dimension). Hand-rolled for speed. */
    fun parseCube(stream: InputStream): Pair<FloatArray, Int>? {
        val text = stream.readBytes()
        var dimension = 0
        var data: FloatArray? = null
        var count = 0
        var i = 0
        val n = text.size
        val vals = FloatArray(3)
        while (i < n) {
            // find line bounds
            var end = i
            while (end < n && text[end] != '\n'.code.toByte()) end++
            var s = i
            while (s < end && (text[s] == ' '.code.toByte() || text[s] == '\t'.code.toByte() || text[s] == '\r'.code.toByte())) s++
            if (s < end) {
                val c = text[s].toInt().toChar()
                if (c.isLetter()) {
                    val line = String(text, s, end - s).trim()
                    if (line.startsWith("LUT_3D_SIZE")) {
                        dimension = line.split(' ', '\t').lastOrNull { it.isNotBlank() }?.trim()?.toIntOrNull() ?: 0
                        if (dimension in 2..128) data = FloatArray(dimension * dimension * dimension * 3)
                    }
                } else if (c != '#') {
                    val arr = data
                    if (arr != null) {
                        var k = 0
                        var p = s
                        var ok = true
                        while (p < end && k < 4) {
                            while (p < end && (text[p] == ' '.code.toByte() || text[p] == '\t'.code.toByte() || text[p] == '\r'.code.toByte())) p++
                            if (p >= end) break
                            val tokStart = p
                            while (p < end && text[p] != ' '.code.toByte() && text[p] != '\t'.code.toByte() && text[p] != '\r'.code.toByte()) p++
                            if (k < 3) {
                                val v = parseNumber(text, tokStart, p)
                                if (v == null) { ok = false; break }
                                vals[k] = v
                            }
                            k++
                        }
                        if (ok && k == 3) {
                            if (count + 3 > arr.size) return null
                            arr[count] = vals[0]; arr[count + 1] = vals[1]; arr[count + 2] = vals[2]
                            count += 3
                        }
                    }
                }
            }
            i = end + 1
        }
        val arr = data ?: return null
        if (dimension <= 0 || count != arr.size) {
            Log.w(TAG, "LUT validation failed (dim=$dimension, values=$count)")
            return null
        }
        return arr to dimension
    }

    private fun parseNumber(b: ByteArray, from: Int, to: Int): Float? {
        var p = from
        var neg = false
        if (p < to && (b[p] == '-'.code.toByte() || b[p] == '+'.code.toByte())) { neg = b[p] == '-'.code.toByte(); p++ }
        var mant = 0L
        var scale = 0
        var digits = 0
        var dot = false
        while (p < to) {
            val ch = b[p].toInt()
            if (ch in 48..57) {
                if (digits < 18) { mant = mant * 10 + (ch - 48); if (dot) scale++ ; digits++ } else if (!dot) scale--
            } else if (ch == '.'.code && !dot) dot = true
            else break
            p++
        }
        if (p < to) {
            // exponent or unusual syntax: fall back to the JDK parser
            return String(b, from, to - from).toFloatOrNull()
        }
        if (digits == 0) return null
        var v = mant.toDouble()
        if (scale > 0) v /= POW10[scale.coerceAtMost(18)] else if (scale < 0) v *= POW10[(-scale).coerceAtMost(18)]
        return (if (neg) -v else v).toFloat()
    }

    private val POW10 = DoubleArray(19) { Math.pow(10.0, it.toDouble()) }

    private fun lutDir() = File(appContext.filesDir, "luts").apply { mkdirs() }
    private fun prefs() = appContext.getSharedPreferences("bettercam", Context.MODE_PRIVATE)

    private fun readIndex(): JSONArray = try {
        JSONArray(prefs().getString(INDEX_KEY, "[]"))
    } catch (_: Exception) {
        JSONArray()
    }

    private fun writeIndex(arr: JSONArray) = prefs().edit().putString(INDEX_KEY, arr.toString()).apply()

    private fun loadSavedCustomLUTs(): List<FilmSimulation> {
        val out = mutableListOf<FilmSimulation>()
        val index = readIndex()
        for (i in 0 until index.length()) {
            val item = index.optJSONObject(i) ?: continue
            val name = item.optString("name")
            val dim = item.optInt("dimension")
            val fileName = item.optString("fileName")
            val f = File(lutDir(), fileName)
            if (!f.exists() || dim <= 0) continue
            val bytes = f.readBytes()
            val fb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            val arr = FloatArray(fb.remaining()).also { fb.get(it) }
            if (arr.size != dim * dim * dim * 3) continue
            out += FilmSimulation(name, FilmStyleType.LUT, arr, dim, linearInput = true, fileName = fileName)
        }
        return out
    }

    /** Imports a user .cube file. Returns the new name or null when parsing failed. */
    fun importCube(uri: Uri, displayName: String): String? {
        val parsed = try {
            appContext.contentResolver.openInputStream(uri)?.use { parseCube(it) }
        } catch (e: Exception) {
            Log.w(TAG, "import failed", e); null
        } ?: return null
        val (data, dim) = parsed
        val fileName = UUID.randomUUID().toString() + ".lutdata"
        val buf = ByteBuffer.allocate(data.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        buf.asFloatBuffer().put(data)
        File(lutDir(), fileName).writeBytes(buf.array())
        val index = readIndex()
        index.put(JSONObject().put("name", displayName).put("dimension", dim).put("fileName", fileName))
        writeIndex(index)
        availableSimulations = availableSimulations + FilmSimulation(displayName, FilmStyleType.LUT, data, dim, true, fileName)
        libraryVersion++
        return displayName
    }

    fun deleteSimulation(sim: FilmSimulation) {
        availableSimulations = availableSimulations.filter { it.id != sim.id }
        sim.fileName?.let { File(lutDir(), it).delete() }
        val index = readIndex()
        val kept = JSONArray()
        for (i in 0 until index.length()) {
            val o = index.optJSONObject(i) ?: continue
            if (o.optString("fileName") != sim.fileName) kept.put(o)
        }
        writeIndex(kept)
        libraryVersion++
    }

    fun renameSimulation(sim: FilmSimulation, newName: String) {
        sim.name = newName
        availableSimulations = availableSimulations.toList()
        val index = readIndex()
        for (i in 0 until index.length()) {
            val o = index.optJSONObject(i) ?: continue
            if (o.optString("fileName") == sim.fileName) o.put("name", newName)
        }
        writeIndex(index)
        libraryVersion++
    }

    // ---------------------------------------------------------------- processing

    /** What the preview / still pipeline should do for a given style. */
    data class Plan(val sim: FilmSimulation?, val intensity: Float, val grain: Float) {
        val isIdentity get() = sim == null && grain <= 0f
    }

    fun plan(styleName: String, lutIntensity: Float, grainIntensity: Float): Plan {
        if (styleName == "STD" && grainIntensity <= 0f) return Plan(null, 0f, 0f)
        val sim = if (styleName != "STD") simulation(styleName) else null
        val grain = if (grainIntensity > 0f && styleName != "STD" && styleName != "MANAGE") grainIntensity else 0f
        return Plan(sim, lutIntensity.coerceIn(0f, 1f), grain)
    }

    /** Applies a film plan to a mutable ARGB_8888 bitmap in place, using all cores. */
    fun processBitmap(bitmap: Bitmap, plan: Plan) {
        if (plan.isIdentity) return
        val w = bitmap.width
        val h = bitmap.height
        val strip = 128
        val tasks = (0 until h step strip).map { y0 ->
            Callable {
                val rows = min(strip, h - y0)
                val px = IntArray(w * rows)
                synchronized(bitmap) { bitmap.getPixels(px, 0, w, 0, y0, w, rows) }
                processPixels(px, plan, seed = y0.toLong() * 7919L + System.nanoTime())
                synchronized(bitmap) { bitmap.setPixels(px, 0, w, 0, y0, w, rows) }
            }
        }
        workers.invokeAll(tasks).forEach { it.get() }
    }

    /** Applies a plan to packed ARGB pixels. Mirrors the GLSL preview shader. */
    fun processPixels(px: IntArray, plan: Plan, seed: Long) {
        val sim = plan.sim
        val lut = sim?.lut
        val n = sim?.dimension ?: 0
        val linear = sim?.linearInput ?: false
        val k = plan.intensity
        val grain = plan.grain
        val contrast = 0.8f + grain * 0.15f
        val opacity = 0.12f + grain * 0.3f
        var rng = seed xor 0x5DEECE66DL
        if (rng == 0L) rng = 1L
        val tmp = FloatArray(3)
        for (i in px.indices) {
            val c = px[i]
            val ri = (c shr 16) and 0xFF
            val gi = (c shr 8) and 0xFF
            val bi = c and 0xFF
            var r = ri / 255f
            var g = gi / 255f
            var b = bi / 255f
            if (lut != null) {
                if (linear) {
                    sampleLut(lut, n, ColorMath.toLinear[ri], ColorMath.toLinear[gi], ColorMath.toLinear[bi], tmp)
                    tmp[0] = ColorMath.linearToSrgb(tmp[0]); tmp[1] = ColorMath.linearToSrgb(tmp[1]); tmp[2] = ColorMath.linearToSrgb(tmp[2])
                } else {
                    sampleLut(lut, n, r, g, b, tmp)
                }
                r += (tmp[0] - r) * k
                g += (tmp[1] - g) * k
                b += (tmp[2] - b) * k
            }
            if (grain > 0f) {
                rng = rng xor (rng shl 13); rng = rng xor (rng ushr 7); rng = rng xor (rng shl 17)
                val noise = ((rng ushr 40).toInt() and 0xFFFFFF) / 16777215f
                val gv = ((noise - 0.5f) * contrast + 0.5f) * 0.4f + 0.3f
                val gray = 0.2126f * r + 0.7152f * g + 0.0722f * b
                val mask = (gray + 0.6f + opacity).coerceIn(0f, 1f)
                r += (softLight(r, gv) - r) * mask
                g += (softLight(g, gv) - g) * mask
                b += (softLight(b, gv) - b) * mask
            }
            px[i] = (0xFF shl 24) or (to8(r) shl 16) or (to8(g) shl 8) or to8(b)
        }
    }

    private fun to8(v: Float): Int = (v * 255f + 0.5f).toInt().coerceIn(0, 255)

    fun softLight(base: Float, s: Float): Float {
        val bb = base.coerceIn(0f, 1f)
        return if (s <= 0.5f) {
            bb - (1f - 2f * s) * bb * (1f - bb)
        } else {
            val d = if (bb <= 0.25f) ((16f * bb - 12f) * bb + 4f) * bb else sqrt(bb)
            bb + (2f * s - 1f) * (d - bb)
        }
    }

    /** Trilinear 3D LUT lookup. */
    fun sampleLut(lut: FloatArray, n: Int, r: Float, g: Float, b: Float, out: FloatArray) {
        val m = (n - 1).toFloat()
        val fr = r.coerceIn(0f, 1f) * m
        val fg = g.coerceIn(0f, 1f) * m
        val fb = b.coerceIn(0f, 1f) * m
        val r0 = fr.toInt().coerceAtMost(n - 2).coerceAtLeast(0)
        val g0 = fg.toInt().coerceAtMost(n - 2).coerceAtLeast(0)
        val b0 = fb.toInt().coerceAtMost(n - 2).coerceAtLeast(0)
        val dr = fr - r0
        val dg = fg - g0
        val db = fb - b0
        val nn = n * n
        for (ch in 0..2) {
            fun v(ri: Int, gi: Int, bi: Int) = lut[((ri + gi * n + bi * nn) * 3) + ch]
            val c00 = v(r0, g0, b0) + (v(r0 + 1, g0, b0) - v(r0, g0, b0)) * dr
            val c10 = v(r0, g0 + 1, b0) + (v(r0 + 1, g0 + 1, b0) - v(r0, g0 + 1, b0)) * dr
            val c01 = v(r0, g0, b0 + 1) + (v(r0 + 1, g0, b0 + 1) - v(r0, g0, b0 + 1)) * dr
            val c11 = v(r0, g0 + 1, b0 + 1) + (v(r0 + 1, g0 + 1, b0 + 1) - v(r0, g0 + 1, b0 + 1)) * dr
            val c0 = c00 + (c10 - c00) * dg
            val c1 = c01 + (c11 - c01) * dg
            out[ch] = c0 + (c1 - c0) * db
        }
    }

    /** Packs a LUT into an RGBA8 2D atlas of size (N*N) x N for the GLES2 preview shader. */
    fun atlasBytes(sim: FilmSimulation): ByteBuffer {
        val n = sim.dimension
        val buf = ByteBuffer.allocateDirect(n * n * n * 4).order(ByteOrder.nativeOrder())
        // Atlas texel (x = r + b*N, y = g)
        for (g in 0 until n) for (b in 0 until n) for (r in 0 until n) {
            val idx = (r + g * n + b * n * n) * 3
            buf.put(to8(sim.lut[idx]).toByte())
            buf.put(to8(sim.lut[idx + 1]).toByte())
            buf.put(to8(sim.lut[idx + 2]).toByte())
            buf.put(0xFF.toByte())
        }
        buf.flip()
        return buf
    }
}

object ColorMath {
    val toLinear = FloatArray(256) { srgbToLinear(it / 255f) }
    private val toSrgbTable = FloatArray(4097) { linearToSrgbExact(it / 4096f) }

    fun srgbToLinear(c: Float): Float =
        if (c <= 0.04045f) c / 12.92f else ((c + 0.055f) / 1.055f).pow(2.4f)

    fun linearToSrgbExact(c: Float): Float {
        val v = c.coerceIn(0f, 1f)
        return if (v <= 0.0031308f) v * 12.92f else 1.055f * v.pow(1f / 2.4f) - 0.055f
    }

    fun linearToSrgb(c: Float): Float {
        val f = c.coerceIn(0f, 1f) * 4096f
        val i = f.toInt().coerceAtMost(4095)
        val t = f - i
        return toSrgbTable[i] + (toSrgbTable[i + 1] - toSrgbTable[i]) * t
    }
}
