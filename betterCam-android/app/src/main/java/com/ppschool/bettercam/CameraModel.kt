package com.ppschool.bettercam

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ppschool.bettercam.camera.CameraController
import com.ppschool.bettercam.camera.Haptics
import com.ppschool.bettercam.camera.Lens
import com.ppschool.bettercam.camera.LensDiscovery
import com.ppschool.bettercam.camera.OrientationTracker
import com.ppschool.bettercam.camera.PhotoCaptureRequest
import com.ppschool.bettercam.camera.ShutterSound
import com.ppschool.bettercam.data.CameraPermissionStatus
import com.ppschool.bettercam.data.ExposureMode
import com.ppschool.bettercam.data.ExposureParameter
import com.ppschool.bettercam.data.ImageQuality
import com.ppschool.bettercam.data.ParameterManager
import com.ppschool.bettercam.data.PhotoResolutionMode
import com.ppschool.bettercam.data.UIWidgets
import com.ppschool.bettercam.data.nextOption
import com.ppschool.bettercam.engine.ExposureAnalyzer
import com.ppschool.bettercam.engine.FilmEngine
import com.ppschool.bettercam.engine.PreviewRenderer
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** Port of Camera.swift: the app state and the glue between UI, parameters and the camera. */
@OptIn(FlowPreview::class)
class CameraModel(app: Application) : AndroidViewModel(app), CameraController.Events, PreviewRenderer.Listener {
    private val context: Context get() = getApplication()
    private val prefs = app.getSharedPreferences("bettercam", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())

    val pm = ParameterManager(app)
    val haptics = Haptics(app)
    private val sound = ShutterSound(app)
    private val orientation = OrientationTracker(app)
    private val controller = CameraController(app, this)
    val renderer = PreviewRenderer(this)
    private val analyzer = ExposureAnalyzer()

    // Lenses (LensManager.swift)
    var lenses by mutableStateOf(listOf<Lens>())
        private set
    var currentLens by mutableStateOf<Lens?>(null)
        private set

    // UI interaction state
    var activeIndex by mutableIntStateOf(0)
    var isAdjustingValue by mutableStateOf(false)
    var exposureIndicatorMode by mutableStateOf(ExposureMode.OFF)
        private set
    var indicatorImage by mutableStateOf<ImageBitmap?>(null)
        private set
    val overlayWidth get() = analyzer.overlayWidth
    val overlayHeight get() = analyzer.overlayHeight

    // Camera status
    var isSensorBusy by mutableStateOf(false)
        private set
    var inFlightPhotos by mutableIntStateOf(0)
        private set
    var is24MPSupported by mutableStateOf(false)
        private set
    var is48MPSupported by mutableStateOf(false)
        private set
    var isRawSupported by mutableStateOf(false)
        private set
    val isProRAWSupported = false // Apple ProRAW has no Android equivalent.
    var lastCaptureResolution by mutableStateOf<String?>(null)
        private set
    var cameraPermission by mutableStateOf(CameraPermissionStatus.UNDETERMINED)
        private set

    var isShowingMenu by mutableStateOf(false)
        private set
    var inCameraView by mutableStateOf(true)
        private set
    var doneTheTip by mutableStateOf(prefs.getBoolean("doneTheTip", false))
        private set
    var hasCompletedTutorial by mutableStateOf(prefs.getBoolean("hasCompletedTutorial", false))
        private set
    var isShowingTutorial by mutableStateOf(false)
        private set
    var isSwitchingLens by mutableStateOf(false)
        private set

    var lutIntensity by mutableFloatStateOf(1f)
    var grainIntensity by mutableFloatStateOf(1f)

    /** Quarter turns the UI is rotated by (set by the landscape workspace). */
    var displayTurns by mutableIntStateOf(1)

    private var isForeground = false
    private var cameraStarted = false
    var permissionRequester: (() -> Unit)? = null

    // Light meter smoothing (SessionManager.setupLightMeter)
    @Volatile private var meterActive = false
    @Volatile private var analysisMode = ExposureMode.OFF
    private var smoothedOffset = 0f
    private var lastMeterUpdate = 0L
    private var lastMeterValue: Float? = null

    val availableImageQualityOptions: List<String>
        get() = pm.imageQualityOptions.filter {
            when (it) {
                ImageQuality.PRORAW -> isProRAWSupported
                ImageQuality.DNG, ImageQuality.DNG_J -> isRawSupported
                else -> true
            }
        }

    val isManualExposureActive get() = pm.isManualExposure
    private val maxBufferCount get() = if (pm.photoResolutionMode == PhotoResolutionMode.HIGH_48MP) 1 else 3
    val isFullyAuthorized get() = cameraPermission == CameraPermissionStatus.AUTHORIZED

    init {
        lenses = LensDiscovery.discover(app, pm.enableFrontCamera)
        currentLens = LensDiscovery.defaultLens(lenses)
        currentLens?.let { updateUIWithLens(it) }
        bindRenderer()
        if (hasCompletedTutorial) startCamera() else isShowingTutorial = true
    }

    // ------------------------------------------------------------------ startup

    fun startCamera() {
        if (cameraStarted) return
        cameraStarted = true
        orientation.start()
        sound.setup(pm.shutterSoundSelection)
        requestPermissionIfNeeded()
        bindLensSelection()
        bindExposureControls()
        bindCaptureSettings()
        bindFocusAndSound()
        pushOutput()
        pushControls()
        manageSession()
    }

    fun requestPermissionIfNeeded() {
        if (!cameraStarted) return
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            cameraPermission = CameraPermissionStatus.AUTHORIZED
        } else if (cameraPermission == CameraPermissionStatus.UNDETERMINED) {
            permissionRequester?.invoke()
        }
    }

    fun onPermissionResult(granted: Boolean) {
        cameraPermission = if (granted) CameraPermissionStatus.AUTHORIZED else CameraPermissionStatus.DENIED
        manageSession()
    }

    fun onForegroundChanged(foreground: Boolean) {
        isForeground = foreground
        if (foreground) {
            if (cameraStarted && cameraPermission != CameraPermissionStatus.AUTHORIZED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            ) cameraPermission = CameraPermissionStatus.AUTHORIZED
            orientation.start()
        } else {
            orientation.stop()
            pm.saveExposureParameters()
        }
        manageSession()
    }

    private fun manageSession() {
        controller.setRunning(
            cameraStarted && isForeground && isFullyAuthorized && inCameraView && !isShowingMenu && currentLens != null
        )
    }

    // ------------------------------------------------------------------ bindings

    private fun bindLensSelection() = viewModelScope.launch {
        snapshotFlow { currentLens }.drop(1).debounce(200).collect { lens ->
            lens ?: return@collect
            if (controller.isUsing(lens)) {
                updateUIWithLens(lens); return@collect
            }
            isSwitchingLens = true
            updateUIWithLens(lens)
            pushOutput()
            pushControls()
            delay(400)
            isSwitchingLens = false
        }
    }

    private fun bindExposureControls() {
        viewModelScope.launch {
            snapshotFlow { pm.ss to pm.iso }.debounce(50).collect {
                pushControls()
                pushOutput()
            }
        }
        viewModelScope.launch {
            snapshotFlow { pm.ev }.drop(1).distinctUntilChanged().debounce(120).collect {
                if (!pm.isManualExposure) pushControls()
            }
        }
        viewModelScope.launch {
            snapshotFlow { pm.ss to pm.iso }.debounce(1000).collect { pm.saveExposureParameters() }
        }
    }

    private fun bindCaptureSettings() {
        viewModelScope.launch {
            snapshotFlow { pm.imageQuality }.collect { q ->
                if (q == ImageQuality.PRORAW && !isProRAWSupported) { pm.imageQuality = ImageQuality.JPEG; return@collect }
                if (pm.photoResolutionMode == PhotoResolutionMode.HIGH_48MP && q != ImageQuality.JPEG) {
                    pm.photoResolutionMode = PhotoResolutionMode.STANDARD
                }
                pushOutput()
            }
        }
        viewModelScope.launch {
            snapshotFlow { pm.photoResolutionMode }.drop(1).distinctUntilChanged().collect { mode ->
                if (mode == PhotoResolutionMode.HIGH_48MP) {
                    if (!is48MPSupported) { pm.photoResolutionMode = PhotoResolutionMode.STANDARD; return@collect }
                    pm.updatePureRawEngine(false)
                    if (pm.imageQuality != ImageQuality.JPEG) pm.imageQuality = ImageQuality.JPEG
                }
                pushOutput()
            }
        }
        viewModelScope.launch {
            snapshotFlow { pm.isPureRawEngineEnabled }.drop(1).distinctUntilChanged().collect { enabled ->
                if (enabled && pm.photoResolutionMode == PhotoResolutionMode.HIGH_48MP) {
                    pm.photoResolutionMode = PhotoResolutionMode.STANDARD
                }
                if (enabled && pm.imageQuality == ImageQuality.PRORAW) pm.imageQuality = ImageQuality.DNG_J
                pushOutput()
            }
        }
    }

    private fun bindFocusAndSound() {
        viewModelScope.launch { snapshotFlow { pm.afMode }.drop(1).collect { pushControls() } }
        viewModelScope.launch { snapshotFlow { pm.shutterSoundSelection }.collect { sound.setup(it) } }
    }

    private fun bindRenderer() = viewModelScope.launch {
        snapshotFlow {
            val plan = if (pm.imageQuality == ImageQuality.DNG) FilmEngine.Plan(null, 0f, 0f)
            else FilmEngine.plan(pm.style, lutIntensity, grainIntensity)
            PreviewRenderer.Params(
                plan = plan,
                turns = displayTurns,
                analyze = exposureIndicatorMode != ExposureMode.OFF || pm.isManualExposure,
                libraryVersion = FilmEngine.libraryVersion,
            ) to (exposureIndicatorMode to pm.isManualExposure)
        }.collect { (params, flags) ->
            analysisMode = flags.first
            meterActive = flags.second
            renderer.params = params
        }
    }

    private fun pushControls() {
        val lens = currentLens ?: return
        val evIndex = ((pm.ev.toFloatOrNull() ?: 0f) / lens.evStep).roundToInt()
        controller.setControls(
            CameraController.Controls(
                manual = pm.isManualExposure,
                exposureNs = ExposureParameter.shutterNanos(pm.ss) ?: 5_000_000L,
                iso = ExposureParameter.isoValue(pm.iso)?.toInt() ?: lens.minISO,
                evIndex = evIndex,
                afContinuous = pm.afMode == "AF-C",
            )
        )
    }

    private fun pushOutput() {
        val lens = currentLens ?: return
        val pureRaw = pm.isPureRawEngineEnabled && lens.supportsRaw
        val q = pm.imageQuality
        val needsRaw = lens.supportsRaw && (q == ImageQuality.DNG || q == ImageQuality.DNG_J || pureRaw)
        val sizeMode = when {
            pm.photoResolutionMode == PhotoResolutionMode.HIGH_48MP && q == ImageQuality.JPEG && !pureRaw ->
                CameraController.SizeMode.HIGH
            needsRaw -> CameraController.SizeMode.RAW_NATIVE
            else -> CameraController.SizeMode.STANDARD
        }
        controller.setOutput(CameraController.OutputConfig(lens, needsRaw, sizeMode))
    }

    private fun updateUIWithLens(lens: Lens) {
        pm.actualSSOptions = lens.availableSSOptions
        pm.actualISOOptions = lens.availableISOOptions
        pm.aperture = lens.aperture
        pm.currentFocalLength = lens.equivalentFocalLength
        pm.validateExposureOptions()
    }

    // ------------------------------------------------------------------ lens manager

    fun switchLens(direction: Int) {
        if (lenses.size <= 1) return
        val i = lenses.indexOfFirst { it.key == currentLens?.key }.coerceAtLeast(0)
        currentLens = lenses[(i + direction + lenses.size) % lenses.size]
    }

    fun setFrontCameraEnabled(enabled: Boolean) {
        pm.updateEnableFrontCamera(enabled)
        lenses = LensDiscovery.discover(context, enabled)
        val keep = lenses.firstOrNull { it.key == currentLens?.key }
        currentLens = keep ?: LensDiscovery.defaultLens(lenses)
    }

    // ------------------------------------------------------------------ dial navigation (DialNavigation.swift)

    fun changeParameter(direction: Int) {
        if (isAdjustingValue) adjustValue(direction)
        else {
            val count = UIWidgets.NULL + 1
            activeIndex = (activeIndex + direction + count) % count
        }
    }

    private fun adjustValue(direction: Int) {
        when (activeIndex) {
            UIWidgets.AF_MODE -> pm.afMode = nextOption(pm.afModeOptions, pm.afMode, direction)
            UIWidgets.STYLE -> pm.style = nextOption(pm.styleOptions, pm.style, direction)
            UIWidgets.SS -> pm.setSS(nextOption(pm.actualSSOptions, pm.ss, direction))
            UIWidgets.EV -> if (!pm.isManualExposure) pm.ev = nextOption(pm.evOptions, pm.ev, direction, isEV = true)
            UIWidgets.ISO -> pm.setISO(nextOption(pm.actualISOOptions, pm.iso, direction))
            UIWidgets.LENS_SWITCH -> switchLens(direction)
            UIWidgets.IMAGE_QUALITY -> pm.imageQuality = nextOption(availableImageQualityOptions, pm.imageQuality, direction)
        }
    }

    fun selectWidget(index: Int) {
        activeIndex = index
        isAdjustingValue = false
    }

    fun toggleAdjustmentMode() {
        if (activeIndex != UIWidgets.NULL && activeIndex != UIWidgets.STYLE) isAdjustingValue = !isAdjustingValue
        if (activeIndex == UIWidgets.STYLE) {
            isAdjustingValue = !isAdjustingValue
            if (pm.style == "MANAGE" && !isAdjustingValue) showCameraView(false)
        }
        if (activeIndex == UIWidgets.MENU) {
            if (!isAdjustingValue) isAdjustingValue = true
            else { showMenu(true); isAdjustingValue = false }
        }
        haptics.impact(Haptics.Style.HEAVY)
    }

    fun showMenu(value: Boolean) { isShowingMenu = value; manageSession() }
    fun showCameraView(value: Boolean) { inCameraView = value; manageSession() }

    fun setExposureMode(mode: ExposureMode) {
        if (mode == exposureIndicatorMode) return
        exposureIndicatorMode = mode
        indicatorImage = null
        analyzer.reset()
    }

    fun completeTutorial() {
        hasCompletedTutorial = true
        prefs.edit().putBoolean("hasCompletedTutorial", true).apply()
        isShowingTutorial = false
        startCamera()
    }

    fun markTipped() {
        doneTheTip = true
        prefs.edit().putBoolean("doneTheTip", true).apply()
    }

    // ------------------------------------------------------------------ actions

    fun takePhoto() {
        val lens = currentLens ?: return
        if (isSensorBusy || inFlightPhotos >= maxBufferCount || isShowingTutorial || !isFullyAuthorized) return
        isSensorBusy = true
        inFlightPhotos += 1
        val manual = pm.isManualExposure
        val request = PhotoCaptureRequest(
            imageQuality = pm.imageQuality,
            highResolution = pm.photoResolutionMode == PhotoResolutionMode.HIGH_48MP,
            isFrontCamera = lens.isFront,
            usePureRawEngine = pm.isPureRawEngineEnabled && lens.supportsRaw,
            styleName = pm.style,
            lutIntensity = lutIntensity,
            grainIntensity = grainIntensity,
            usesManualExposure = manual,
            manualExposureNs = if (manual) ExposureParameter.shutterNanos(pm.ss)?.coerceIn(lens.minExposureNs, lens.maxExposureNs) else null,
            manualISO = if (manual) ExposureParameter.isoValue(pm.iso)?.toInt()?.coerceIn(lens.minISO, lens.maxISO) else null,
            jpegOrientation = orientation.jpegOrientation(lens.sensorOrientation, lens.isFront),
        )
        controller.capture(request)
        sound.play()
        haptics.impact(Haptics.Style.HEAVY)
    }

    /** Tap-to-focus. [lx],[ly] are normalised viewfinder coordinates (y down) in the rotated UI. */
    fun focusAtView(lx: Float, ly: Float) {
        val lens = currentLens ?: return
        var x = lx
        var y = ly
        repeat(((displayTurns % 4) + 4) % 4) { val nx = 1f - y; val ny = x; x = nx; y = ny }
        if (lens.isFront) x = 1f - x // undo the mirrored selfie preview
        val (sx, sy) = when (lens.sensorOrientation) {
            90 -> y to 1f - x
            180 -> 1f - x to 1f - y
            270 -> 1f - y to x
            else -> x to y
        }
        controller.focus(sx, sy)
    }

    // ------------------------------------------------------------------ CameraController.Events (camera thread)

    override fun onCapabilities(caps: CameraController.Capabilities) = main.post {
        is24MPSupported = caps.supports24MP
        is48MPSupported = caps.supports48MP
        isRawSupported = caps.supportsRaw
        if (!caps.supports48MP && pm.photoResolutionMode == PhotoResolutionMode.HIGH_48MP) {
            pm.photoResolutionMode = PhotoResolutionMode.STANDARD
        }
    }.let { }

    override fun onPreviewSize(size: Size) = renderer.setBufferSize(size.width, size.height)

    override fun onSensorReleased(resolution: String?) = main.post {
        isSensorBusy = false
        if (resolution != null) lastCaptureResolution = resolution
    }.let { }

    override fun onCaptureFailed() = main.post {
        isSensorBusy = false
        inFlightPhotos = (inFlightPhotos - 1).coerceAtLeast(0)
    }.let { }

    override fun onBufferReleased() = main.post {
        inFlightPhotos = (inFlightPhotos - 1).coerceAtLeast(0)
    }.let { }

    override fun onCameraError(message: String) = main.post {
        isSensorBusy = false
        android.util.Log.w("CameraModel", message)
    }.let { }

    // ------------------------------------------------------------------ PreviewRenderer.Listener (GL thread)

    override fun onCameraSurfaceReady(texture: SurfaceTexture) {
        controller.setPreviewTexture(texture)
    }

    override fun onAnalysisFrame(rgba: ByteBuffer, width: Int, height: Int) {
        val mode = analysisMode
        val result = analyzer.analyze(rgba, width, height, mode)
        val image = result.image?.asImageBitmap()
        main.post { if (exposureIndicatorMode == mode) indicatorImage = image }
        if (meterActive) updateMeter(ExposureAnalyzer.offsetStops(result.meanLinear))
    }

    private fun updateMeter(raw: Float) {
        smoothedOffset = smoothedOffset * 0.75f + raw * 0.25f
        val now = SystemClock.uptimeMillis()
        if (now - lastMeterUpdate <= 120) return
        var display = smoothedOffset
        if (abs(display) < 0.12f) display = 0f
        display = (display * 10f).roundToInt() / 10f
        lastMeterValue?.let { if (abs(display - it) < 0.1f) return }
        lastMeterUpdate = now
        lastMeterValue = display
        val text = String.format(Locale.US, "%+.1f", display)
        main.post { if (pm.isManualExposure && pm.ev != text) pm.ev = text }
    }

    override fun onCleared() {
        controller.setRunning(false)
        renderer.release()
        orientation.stop()
    }
}
