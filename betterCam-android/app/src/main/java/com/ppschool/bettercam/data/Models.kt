package com.ppschool.bettercam.data

object ParameterAvailable {
    val ISO_OPTIONS = listOf(
        "AUTO", "50", "64", "100", "125", "160", "200", "250", "320", "400", "500", "640", "800",
        "1000", "1250", "1600", "2000", "2500", "3200", "4000", "5000", "6400"
    )
    val SS_OPTIONS = listOf(
        "AUTO", "1", "0.8", "0.6", "0.5", "0.4", "1/3", "1/4", "1/5", "1/6",
        "1/8", "1/10", "1/13", "1/15", "1/20", "1/25", "1/30", "1/40", "1/50",
        "1/60", "1/80", "1/100", "1/125", "1/160", "1/200", "1/250", "1/320",
        "1/400", "1/500", "1/640", "1/800", "1/1000", "1/1250", "1/1600",
        "1/2000", "1/2500", "1/3200", "1/4000", "1/5000", "1/6400", "1/8000",
        "1/10000", "1/12500", "1/16000", "1/20000", "1/25000", "1/32000",
        "1/40000", "1/50000", "1/64000"
    )
    val EV_OPTIONS = listOf(
        "-5.0", "-4.7", "-4.3", "-4.0", "-3.7", "-3.3", "-3.0", "-2.7", "-2.3", "-2.0",
        "-1.7", "-1.3", "-1.0", "-0.7", "-0.3", "0.0",
        "+0.3", "+0.7", "+1.0", "+1.3", "+1.7", "+2.0", "+2.3", "+2.7", "+3.0", "+3.3",
        "+3.7", "+4.0", "+4.3", "+4.7", "+5.0"
    )
}

enum class CameraPermissionStatus { UNDETERMINED, AUTHORIZED, DENIED }

/** Index order of the on-screen widgets; the dial walks through them in this order. */
object UIWidgets {
    const val IMAGE_QUALITY = 0
    const val LENS_SWITCH = 1
    const val AF_MODE = 2
    const val WB_MODE = 3
    const val MENU = 4
    const val SS = 5
    const val APERTURE = 6
    const val EV = 7
    const val ISO = 8
    const val STYLE = 9
    const val MAX = STYLE
    const val NULL = MAX + 1
}

enum class ExposureMode { WAVEFORM, HISTOGRAM, OFF }

enum class PhotoResolutionMode(val raw: String) { STANDARD("24MP"), HIGH_48MP("48MP") }

enum class ShutterSoundMode(val raw: String) {
    SONY("shutter_eqed_gained"),
    PANASONIC("s1m2_shutter_gained");

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw }
    }
}

object ImageQuality {
    const val DNG_J = "DNG+J"
    const val DNG = "DNG"
    const val PRORAW = "ProRAW"
    const val JPEG = "JPEG"
    val ALL = listOf(DNG_J, DNG, PRORAW, JPEG)
}
