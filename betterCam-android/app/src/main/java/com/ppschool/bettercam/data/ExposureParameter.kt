package com.ppschool.bettercam.data

import kotlin.math.abs

object ExposureParameter {
    const val AUTO = "AUTO"

    fun isoValue(s: String): Float? = normalizedISO(s).toFloatOrNull()

    fun normalizedISO(s: String): String = if (s.startsWith("ISO ")) s.drop(4) else s

    fun shutterSeconds(s: String): Double? {
        s.toDoubleOrNull()?.let { if (it > 0) return it }
        val parts = s.split("/")
        if (parts.size == 2) {
            val n = parts[0].toDoubleOrNull()
            val d = parts[1].toDoubleOrNull()
            if (n != null && d != null && n > 0 && d > 0) return n / d
        }
        return null
    }

    fun shutterNanos(s: String): Long? = shutterSeconds(s)?.let { (it * 1_000_000_000.0).toLong() }

    fun validatedSS(ss: String, options: List<String>): String =
        nearestOption(options, ss) { shutterSeconds(it) }

    fun validatedISO(iso: String, options: List<String>): String =
        nearestOption(options, normalizedISO(iso)) { isoValue(it)?.toDouble() }

    private fun nearestOption(options: List<String>, current: String, value: (String) -> Double?): String {
        if (options.isEmpty()) return current
        if (current in options) return current
        if (current == AUTO) return if (AUTO in options) AUTO else options.first()
        val manual = options.filter { it != AUTO }
        val cur = value(current) ?: return manual.firstOrNull() ?: options.first()
        return manual.minByOrNull { opt -> value(opt)?.let { abs(it - cur) } ?: Double.MAX_VALUE }
            ?: manual.firstOrNull() ?: options.first()
    }

    fun supportedISO(minIso: Int, maxIso: Int): List<String> = ParameterAvailable.ISO_OPTIONS.filter {
        if (it == AUTO) return@filter true
        val v = isoValue(it) ?: return@filter false
        v >= minIso && v <= maxIso
    }

    fun supportedSS(minNs: Long, maxNs: Long): List<String> = ParameterAvailable.SS_OPTIONS.filter {
        if (it == AUTO) return@filter true
        val ns = shutterNanos(it) ?: return@filter false
        ns in minNs..maxNs
    }
}

/** Dial stepping helper (wraps around except for EV). */
fun nextOption(options: List<String>, current: String, direction: Int, isEV: Boolean = false): String {
    if (options.isEmpty()) return current
    val idx = options.indexOf(current).let { if (it < 0) 0 else it }
    val proposed = idx + direction
    if (isEV) return if (proposed in options.indices) options[proposed] else current
    val wrapped = ((proposed % options.size) + options.size) % options.size
    return options[wrapped]
}
