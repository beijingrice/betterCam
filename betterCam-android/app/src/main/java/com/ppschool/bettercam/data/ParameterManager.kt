package com.ppschool.bettercam.data

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.ppschool.bettercam.engine.FilmEngine
import com.ppschool.bettercam.widget.ShutterWidgetProvider

/**
 * Port of ParameterManager.swift. Holds every user-facing camera parameter and
 * implements the SS/ISO <-> AUTO coupling rules.
 */
class ParameterManager(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("bettercam", Context.MODE_PRIVATE)
    private val shared = ShutterCounter.prefs(appContext)

    private var _ss by mutableStateOf("1/200")
    private var _iso by mutableStateOf("100")
    var ev by mutableStateOf("0.0")
    var style by mutableStateOf("STD")
    var imageQuality by mutableStateOf(ImageQuality.JPEG)
    var afMode by mutableStateOf("AF-C")
    var wbMode by mutableStateOf("AWB")
    var aperture by mutableStateOf("F1.8")
    var currentFocalLength by mutableStateOf(26)
    var photoResolutionMode by mutableStateOf(PhotoResolutionMode.STANDARD)

    var actualSSOptions by mutableStateOf(listOf<String>())
    var actualISOOptions by mutableStateOf(listOf<String>())
    var styleOptions by mutableStateOf(listOf<String>())
    val imageQualityOptions = ImageQuality.ALL
    val afModeOptions = listOf("AF-C", "AF-S")
    val evOptions = ParameterAvailable.EV_OPTIONS

    // Applied on next launch (AppStorage equivalents).
    var enablePermanentStorage by mutableStateOf(prefs.getBoolean(KEY_PERMANENT, false))
        private set
    var preferAUTO by mutableStateOf(prefs.getBoolean(KEY_PREFER_AUTO, false))
        private set

    // Applied immediately.
    var enableFrontCamera by mutableStateOf(prefs.getBoolean(KEY_FRONT, false))
        private set
    var shutterSoundSelection by mutableStateOf(
        ShutterSoundMode.from(prefs.getString(KEY_SOUND, null)) ?: ShutterSoundMode.SONY
    )
        private set
    var isPureRawEngineEnabled by mutableStateOf(prefs.getBoolean(KEY_PURE_RAW, false))
        private set

    private var lastSS = "1/200"
    private var lastISO = "100"
    private var isAutoUpdating = false

    val ss: String get() = _ss
    val iso: String get() = _iso

    init {
        syncAllLUTsToOptions()
        loadExposureParameters()
    }

    fun syncAllLUTsToOptions() {
        styleOptions = (FilmEngine.availableSimulations.map { it.name } + "MANAGE").distinct()
        if (style !in styleOptions) style = "STD"
    }

    // ---- Setters with the AUTO coupling logic (replaces the Combine sinks) ----

    fun setSS(value: String) {
        if (value == _ss) return
        _ss = value
        if (isAutoUpdating) return
        isAutoUpdating = true
        try {
            if (value == ExposureParameter.AUTO && _iso != ExposureParameter.AUTO) {
                lastISO = _iso
                _iso = ExposureParameter.AUTO
                ev = "0.0"
            } else if (value != ExposureParameter.AUTO && _iso == ExposureParameter.AUTO) {
                _iso = if (actualISOOptions.isEmpty()) lastISO
                else ExposureParameter.validatedISO(lastISO, actualISOOptions)
            }
        } finally {
            isAutoUpdating = false
        }
    }

    fun setISO(value: String) {
        if (value == _iso) return
        _iso = value
        if (isAutoUpdating) return
        isAutoUpdating = true
        try {
            if (value == ExposureParameter.AUTO && _ss != ExposureParameter.AUTO) {
                lastSS = _ss
                _ss = ExposureParameter.AUTO
                ev = "0.0"
            } else if (value != ExposureParameter.AUTO && _ss == ExposureParameter.AUTO) {
                _ss = if (actualSSOptions.isEmpty()) lastSS
                else ExposureParameter.validatedSS(lastSS, actualSSOptions)
            }
        } finally {
            isAutoUpdating = false
        }
    }

    val isManualExposure: Boolean
        get() = _ss != ExposureParameter.AUTO && _iso != ExposureParameter.AUTO

    fun validateExposureOptions() {
        if (actualSSOptions.isEmpty() && actualISOOptions.isEmpty()) return
        isAutoUpdating = true
        try {
            if (_ss == ExposureParameter.AUTO || _iso == ExposureParameter.AUTO ||
                actualSSOptions.size <= 1 || actualISOOptions.size <= 1
            ) {
                _ss = ExposureParameter.AUTO
                _iso = ExposureParameter.AUTO
                ev = "0.0"
                return
            }
            _ss = ExposureParameter.validatedSS(_ss, actualSSOptions)
            _iso = ExposureParameter.validatedISO(_iso, actualISOOptions)
            if (_ss != ExposureParameter.AUTO) lastSS = _ss
            if (_iso != ExposureParameter.AUTO) lastISO = _iso
        } finally {
            isAutoUpdating = false
        }
    }

    // ---- Persistence ----

    fun saveExposureParameters() {
        if (!enablePermanentStorage) return
        val storedISO = ExposureParameter.normalizedISO(_iso)
        prefs.edit().putString("SS", _ss).putString("ISO", storedISO).apply()
        shared.edit().putString(ShutterCounter.LAST_SS_KEY, _ss)
            .putString(ShutterCounter.LAST_ISO_KEY, storedISO).apply()
        ShutterWidgetProvider.refreshAll(appContext)
    }

    private fun loadExposureParameters() {
        if (preferAUTO) {
            _ss = ExposureParameter.AUTO
            _iso = ExposureParameter.AUTO
            shared.edit().putString(ShutterCounter.LAST_SS_KEY, _ss)
                .putString(ShutterCounter.LAST_ISO_KEY, _iso).apply()
            return
        }
        if (enablePermanentStorage) {
            _ss = prefs.getString("SS", null) ?: "1/200"
            _iso = ExposureParameter.normalizedISO(prefs.getString("ISO", null) ?: "100")
            if (_ss != ExposureParameter.AUTO) lastSS = _ss
            if (_iso != ExposureParameter.AUTO) lastISO = _iso
        }
    }

    fun updateEnablePermanentStorage(value: Boolean) {
        enablePermanentStorage = value
        prefs.edit().putBoolean(KEY_PERMANENT, value).apply()
    }

    fun updatePreferAUTO(value: Boolean) {
        preferAUTO = value
        prefs.edit().putBoolean(KEY_PREFER_AUTO, value).apply()
    }

    fun updateEnableFrontCamera(value: Boolean) {
        enableFrontCamera = value
        prefs.edit().putBoolean(KEY_FRONT, value).apply()
    }

    fun updateShutterSound(value: ShutterSoundMode) {
        shutterSoundSelection = value
        prefs.edit().putString(KEY_SOUND, value.raw).apply()
    }

    fun updatePureRawEngine(value: Boolean) {
        isPureRawEngineEnabled = value
        prefs.edit().putBoolean(KEY_PURE_RAW, value).apply()
    }

    companion object {
        private const val KEY_PERMANENT = "enablePermanentParameterStorage"
        private const val KEY_PREFER_AUTO = "perferAUTO"
        private const val KEY_FRONT = "enableFrontCamera"
        private const val KEY_SOUND = "shutterSoundSelection"
        private const val KEY_PURE_RAW = "isPureRawEngineEnabled"
    }
}
