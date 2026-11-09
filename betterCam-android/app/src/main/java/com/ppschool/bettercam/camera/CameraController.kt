package com.ppschool.bettercam.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.MeteringRectangle
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import com.ppschool.bettercam.data.ShutterCounter
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Camera2 session owner (SessionManager.swift). All camera work happens on one HandlerThread;
 * still development happens on a serial processing executor, like the iOS processingQueue.
 */
class CameraController(context: Context, private val events: Events) {

    interface Events {
        fun onCapabilities(caps: Capabilities)
        fun onPreviewSize(size: Size)
        fun onSensorReleased(resolution: String?)
        fun onCaptureFailed()
        fun onBufferReleased()
        fun onCameraError(message: String)
    }

    /** [standardMP]/[highMP] are the phone's real capture sizes; [highMP] is null when there is no larger mode. */
    data class Capabilities(val standardMP: Int?, val highMP: Int?, val supportsRaw: Boolean)

    enum class SizeMode { STANDARD, RAW_NATIVE, HIGH }

    data class OutputConfig(val lens: Lens, val needsRaw: Boolean, val sizeMode: SizeMode)

    data class Controls(
        val manual: Boolean = false,
        val exposureNs: Long = 5_000_000L,
        val iso: Int = 100,
        val evIndex: Int = 0,
        val afContinuous: Boolean = true,
    )

    private data class SessionKey(val cameraId: String, val raw: Boolean, val jpeg: Size, val maxRes: Boolean)

    private class CaptureCtx(val id: Long, val request: PhotoCaptureRequest, val expectedImages: Int) {
        var timestamp = -1L
        var result: TotalCaptureResult? = null
        var rawFrame: RawDeveloper.RawFrame? = null
        var rawStarted = false
        var receivedImages = 0
        var pendingJobs = 0
        var captureFinished = false
        var released = false
    }

    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val thread = HandlerThread("bettercam.session").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }
    private val processing = Executors.newSingleThreadExecutor(BackgroundThreads.factory("bettercam.processing"))

    // State (camera thread only)
    private var running = false
    private var config: OutputConfig? = null
    private var controls = Controls()
    private var previewTexture: SurfaceTexture? = null
    private var previewSurface: Surface? = null
    private var device: CameraDevice? = null
    private var opening: String? = null
    private var chars: CameraCharacteristics? = null
    private var dims: PhotoDimensions? = null
    private var session: CameraCaptureSession? = null
    private var activeKey: SessionKey? = null
    private var configuring = false
    private var jpegReader: ImageReader? = null
    private var rawReader: ImageReader? = null
    private var focusRegion: MeteringRectangle? = null
    private var lastAfContinuous: Boolean? = null
    private var highResBroken = false

    private val nextId = AtomicLong(1)
    private val contexts = HashMap<Long, CaptureCtx>()
    private val byTimestamp = HashMap<Long, CaptureCtx>()
    private val pendingJpeg = HashMap<Long, ByteArray>()
    private val pendingRaw = HashMap<Long, RawDeveloper.RawFrame>()

    // ------------------------------------------------------------------ public API

    fun setPreviewTexture(st: SurfaceTexture?) = handler.post {
        if (st !== previewTexture) {
            previewTexture = st
            closeSession()
            reconcile()
        }
    }

    fun setOutput(config: OutputConfig) = handler.post {
        this.config = config
        reconcile()
    }

    fun setControls(c: Controls) = handler.post {
        controls = c
        if (lastAfContinuous == true && !c.afContinuous) triggerAfLock()
        lastAfContinuous = c.afContinuous
        startRepeating()
    }

    fun setRunning(value: Boolean) = handler.post {
        if (running == value) return@post
        running = value
        reconcile()
    }

    /** Point in normalised sensor coordinates (0..1, sensor orientation). */
    fun focus(nx: Float, ny: Float) = handler.post { doFocus(nx, ny) }

    fun capture(request: PhotoCaptureRequest) = handler.post { doCapture(request) }

    fun isUsing(lens: Lens): Boolean = device?.id == lens.cameraId && config?.lens?.key == lens.key

    // ------------------------------------------------------------------ lifecycle

    private fun reconcile() {
        val cfg = config
        val st = previewTexture
        if (!running || cfg == null || st == null) {
            closeCamera()
            return
        }
        val dev = device
        if (dev == null || dev.id != cfg.lens.cameraId) {
            if (opening == cfg.lens.cameraId) return
            closeCamera()
            openCamera(cfg.lens.cameraId)
            return
        }
        if (configuring) return
        val key = sessionKey(cfg) ?: return
        if (session == null || key != activeKey) {
            createSession(dev, st, key)
        } else {
            startRepeating()
        }
    }

    @SuppressLint("MissingPermission")
    private fun openCamera(id: String) {
        opening = id
        try {
            manager.openCamera(id, executor, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    opening = null
                    if (!running || config?.lens?.cameraId != id) {
                        camera.close(); reconcile(); return
                    }
                    device = camera
                    val c = manager.getCameraCharacteristics(id)
                    chars = c
                    dims = buildDimensions(c)
                    highResBroken = false
                    lastAfContinuous = null
                    publishCapabilities()
                    reconcile()
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    if (device === camera) cleanupDevice()
                    opening = null
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    Log.e(TAG, "camera error $error")
                    camera.close()
                    if (device === camera) cleanupDevice()
                    opening = null
                    events.onCameraError("Camera error $error")
                }
            })
        } catch (e: Exception) {
            opening = null
            Log.e(TAG, "openCamera failed", e)
            events.onCameraError(e.message ?: "openCamera failed")
        }
    }

    private fun buildDimensions(c: CameraCharacteristics): PhotoDimensions {
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val regular = map?.getOutputSizes(ImageFormat.JPEG)?.toList() ?: emptyList()
        var maxRes = emptyList<Size>()
        if (Build.VERSION.SDK_INT >= 31) {
            val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
            if (caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_ULTRA_HIGH_RESOLUTION_SENSOR)) {
                maxRes = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP_MAXIMUM_RESOLUTION)
                    ?.getOutputSizes(ImageFormat.JPEG)?.toList() ?: emptyList()
            }
        }
        return PhotoDimensions(regular, maxRes)
    }

    private fun publishCapabilities() {
        val d = dims
        val lens = config?.lens
        events.onCapabilities(
            Capabilities(
                standardMP = PhotoDimensions.megapixels(d?.standard),
                highMP = if (highResBroken) null else PhotoDimensions.megapixels(d?.high),
                supportsRaw = lens?.supportsRaw == true,
            )
        )
    }

    private fun sessionKey(cfg: OutputConfig): SessionKey? {
        val d = dims ?: return null
        val raw = cfg.needsRaw && cfg.lens.supportsRaw
        val useHigh = cfg.sizeMode == SizeMode.HIGH && d.high != null && !highResBroken
        val jpeg = when {
            useHigh -> d.high!!
            cfg.sizeMode == SizeMode.RAW_NATIVE -> d.nativeRAW ?: d.standard
            else -> d.standard
        } ?: return null
        return SessionKey(cfg.lens.cameraId, raw, jpeg, useHigh && d.highNeedsMaxResolution)
    }

    private fun choosePreviewSize(c: CameraCharacteristics): Size {
        val sizes = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(SurfaceTexture::class.java)?.toList() ?: return Size(1440, 1080)
        val ok = sizes.filter { it.height <= 1080 && it.width <= 1920 }
        val fourThree = ok.filter { abs(it.width.toFloat() / it.height - 4f / 3f) < 0.02f }
        return (fourThree.ifEmpty { ok }.ifEmpty { sizes }).maxBy { it.width.toLong() * it.height }
    }

    private fun createSession(dev: CameraDevice, st: SurfaceTexture, key: SessionKey) {
        closeSession()
        val c = chars ?: return
        configuring = true
        val preview = choosePreviewSize(c)
        st.setDefaultBufferSize(preview.width, preview.height)
        val surface = Surface(st)
        previewSurface = surface
        events.onPreviewSize(preview)

        val jpeg = ImageReader.newInstance(key.jpeg.width, key.jpeg.height, ImageFormat.JPEG, 4)
        jpeg.setOnImageAvailableListener({ onJpeg(it) }, handler)
        jpegReader = jpeg
        val outputs = mutableListOf(OutputConfiguration(surface), OutputConfiguration(jpeg.surface))
        if (key.maxRes && Build.VERSION.SDK_INT >= 31) {
            outputs[0].addSensorPixelModeUsed(CameraMetadata.SENSOR_PIXEL_MODE_DEFAULT)
            outputs[1].addSensorPixelModeUsed(CameraMetadata.SENSOR_PIXEL_MODE_MAXIMUM_RESOLUTION)
        }
        if (key.raw) {
            val rawSize = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(ImageFormat.RAW_SENSOR)?.maxByOrNull { it.width.toLong() * it.height }
            if (rawSize != null) {
                val raw = ImageReader.newInstance(rawSize.width, rawSize.height, ImageFormat.RAW_SENSOR, 4)
                raw.setOnImageAvailableListener({ onRaw(it) }, handler)
                rawReader = raw
                outputs += OutputConfiguration(raw.surface).also {
                    if (key.maxRes && Build.VERSION.SDK_INT >= 31) it.addSensorPixelModeUsed(CameraMetadata.SENSOR_PIXEL_MODE_DEFAULT)
                }
            }
        }
        val cfg = SessionConfiguration(SessionConfiguration.SESSION_REGULAR, outputs, executor,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    configuring = false
                    if (device !== dev) { s.close(); return }
                    session = s
                    activeKey = key
                    startRepeating()
                    reconcile()
                }

                override fun onConfigureFailed(s: CameraCaptureSession) {
                    configuring = false
                    Log.e(TAG, "session configure failed for $key")
                    if (key.maxRes || key.jpeg == dims?.high) {
                        highResBroken = true
                        publishCapabilities()
                        reconcile()
                    } else {
                        events.onCameraError("Session configuration failed")
                    }
                }
            })
        try {
            dev.createCaptureSession(cfg)
        } catch (e: Exception) {
            configuring = false
            Log.e(TAG, "createCaptureSession failed", e)
            events.onCameraError(e.message ?: "session failed")
        }
    }

    private fun closeSession() {
        try { session?.close() } catch (_: Exception) {}
        session = null
        activeKey = null
        jpegReader?.close(); jpegReader = null
        rawReader?.close(); rawReader = null
        previewSurface?.release(); previewSurface = null
        failOutstanding()
    }

    private fun closeCamera() {
        closeSession()
        device?.close()
        cleanupDevice()
    }

    private fun cleanupDevice() {
        session = null
        activeKey = null
        device = null
        configuring = false
    }

    // ------------------------------------------------------------------ requests

    private fun applyControls(b: CaptureRequest.Builder, still: Boolean, req: PhotoCaptureRequest? = null) {
        val c = chars ?: return
        val lens = config?.lens ?: return
        b.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        if (Build.VERSION.SDK_INT >= 30 && c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) != null) {
            b.set(CaptureRequest.CONTROL_ZOOM_RATIO, lens.zoomRatio)
        }
        val afModes = c.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: IntArray(0)
        when {
            controls.afContinuous && afModes.contains(CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE) ->
                b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            afModes.contains(CameraMetadata.CONTROL_AF_MODE_AUTO) ->
                b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_AUTO)
        }
        focusRegion?.let { r ->
            if ((c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0) > 0) b.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(r))
            if ((c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0) > 0) b.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(r))
        }
        val manual = (req?.usesManualExposure ?: controls.manual) && lens.supportsManual
        if (manual) {
            val ns = (req?.manualExposureNs ?: controls.exposureNs).coerceIn(lens.minExposureNs, lens.maxExposureNs)
            val iso = (req?.manualISO ?: controls.iso).coerceIn(lens.minISO, lens.maxISO)
            b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_OFF)
            b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, ns)
            b.set(CaptureRequest.SENSOR_SENSITIVITY, iso)
            b.set(CaptureRequest.SENSOR_FRAME_DURATION, max(ns, if (still) ns else 33_333_333L))
        } else {
            b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
            b.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION,
                controls.evIndex.coerceIn(lens.evRange.first, lens.evRange.last))
        }
        b.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
    }

    private fun previewBuilder(): CaptureRequest.Builder? {
        val dev = device ?: return null
        val surface = previewSurface ?: return null
        return try {
            dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(surface)
                applyControls(this, still = false)
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun startRepeating() {
        val s = session ?: return
        val b = previewBuilder() ?: return
        try {
            s.setRepeatingRequest(b.build(), null, handler)
        } catch (e: Exception) {
            Log.w(TAG, "setRepeatingRequest failed", e)
        }
    }

    private fun triggerAfLock() {
        val s = session ?: return
        val b = previewBuilder() ?: return
        b.set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_START)
        runCatching { s.capture(b.build(), null, handler) }
    }

    private fun doFocus(nx: Float, ny: Float) {
        val c = chars ?: return
        val s = session ?: return
        val active = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
        val half = (min(active.width(), active.height()) * 0.08f).toInt()
        val cx = (nx.coerceIn(0f, 1f) * active.width()).toInt()
        val cy = (ny.coerceIn(0f, 1f) * active.height()).toInt()
        val left = (cx - half).coerceIn(0, active.width() - 2 * half)
        val top = (cy - half).coerceIn(0, active.height() - 2 * half)
        focusRegion = MeteringRectangle(left, top, 2 * half, 2 * half, MeteringRectangle.METERING_WEIGHT_MAX - 1)
        val b = previewBuilder() ?: return
        if (controls.afContinuous) {
            b.set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_CANCEL)
        } else {
            b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_AUTO)
            b.set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_START)
        }
        runCatching { s.capture(b.build(), null, handler) }
        startRepeating()
    }

    // ------------------------------------------------------------------ capture

    private fun doCapture(req: PhotoCaptureRequest) {
        val s = session
        val dev = device
        val jpeg = jpegReader
        val key = activeKey
        if (s == null || dev == null || jpeg == null || key == null) {
            Log.w(TAG, "capture without an active session")
            events.onCaptureFailed(); return
        }
        val raw = rawReader
        val wantRaw = req.needsRaw && raw != null
        val wantJpeg = req.needsJpeg || (req.needsRaw && raw == null)
        val b = try { dev.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE) } catch (e: Exception) {
            events.onCaptureFailed(); return
        }
        if (wantJpeg) b.addTarget(jpeg.surface)
        if (wantRaw) b.addTarget(raw!!.surface)
        applyControls(b, still = true, req = req)
        b.set(CaptureRequest.JPEG_ORIENTATION, req.jpegOrientation)
        b.set(CaptureRequest.JPEG_QUALITY, 95.toByte())
        b.set(CaptureRequest.CONTROL_CAPTURE_INTENT, CameraMetadata.CONTROL_CAPTURE_INTENT_STILL_CAPTURE)
        if (wantRaw) {
            val modes = chars?.get(CameraCharacteristics.STATISTICS_INFO_AVAILABLE_LENS_SHADING_MAP_MODES) ?: IntArray(0)
            if (modes.contains(CameraMetadata.STATISTICS_LENS_SHADING_MAP_MODE_ON)) {
                b.set(CaptureRequest.STATISTICS_LENS_SHADING_MAP_MODE, CameraMetadata.STATISTICS_LENS_SHADING_MAP_MODE_ON)
            }
        }
        if (key.maxRes && wantJpeg && Build.VERSION.SDK_INT >= 31) {
            b.set(CaptureRequest.SENSOR_PIXEL_MODE, CameraMetadata.SENSOR_PIXEL_MODE_MAXIMUM_RESOLUTION)
        }
        val id = nextId.getAndIncrement()
        b.setTag(id)
        val ctx = CaptureCtx(id, req.copy(imageQuality = if (!wantRaw && req.needsRaw) "JPEG" else req.imageQuality),
            (if (wantJpeg) 1 else 0) + (if (wantRaw) 1 else 0))
        contexts[id] = ctx
        Log.d(TAG, "capture #$id jpeg=$wantJpeg raw=$wantRaw quality=${req.imageQuality} pureRaw=${req.usePureRawEngine}")
        try {
            s.capture(b.build(), captureCallback, handler)
            // Safety net: if the camera never answers, report it and unlock the shutter.
            val exposureMs = (req.manualExposureNs ?: 0L) / 1_000_000L
            handler.postDelayed({ captureTimedOut(ctx) }, CAPTURE_TIMEOUT_MS + exposureMs)
        } catch (e: Exception) {
            Log.e(TAG, "capture failed", e)
            contexts.remove(id)
            events.onCaptureFailed()
        }
    }

    /**
     * Called when a still produced no result, failure or buffer-lost callback in time. A conforming
     * HAL always reports one of those, so this only logs the problem and unlocks the shutter.
     */
    private fun captureTimedOut(ctx: CaptureCtx) {
        if (ctx.captureFinished || ctx.released) return
        Log.w(TAG, "capture #${ctx.id}: no result from the camera after ${CAPTURE_TIMEOUT_MS} ms (request dropped by the HAL?)")
        ctx.released = true
        contexts.remove(ctx.id)
        if (ctx.timestamp >= 0) byTimestamp.remove(ctx.timestamp)
        ctx.rawFrame = null
        events.onCaptureFailed()
    }

    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureStarted(session: CameraCaptureSession, request: CaptureRequest, timestamp: Long, frameNumber: Long) {
            val ctx = contexts[request.tag as? Long ?: return] ?: return
            ctx.timestamp = timestamp
            byTimestamp[timestamp] = ctx
            pendingJpeg.remove(timestamp)?.let { handleJpeg(ctx, it) }
            pendingRaw.remove(timestamp)?.let { handleRaw(ctx, it) }
        }

        override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
            val ctx = contexts[request.tag as? Long ?: return] ?: return
            ctx.result = result
            ctx.captureFinished = true
            ShutterCounter.increment(appContext)
            val size = activeKey?.jpeg
            events.onSensorReleased(size?.let { "${it.width}×${it.height}" })
            maybeProcessRaw(ctx)
            maybeRelease(ctx)
        }

        override fun onCaptureFailed(session: CameraCaptureSession, request: CaptureRequest, failure: CaptureFailure) {
            val ctx = contexts.remove(request.tag as? Long ?: return) ?: return
            if (ctx.timestamp >= 0) byTimestamp.remove(ctx.timestamp)
            ctx.rawFrame = null
            ctx.released = true
            events.onCaptureFailed()
        }

        override fun onCaptureBufferLost(session: CameraCaptureSession, request: CaptureRequest, target: Surface, frameNumber: Long) {
            val ctx = contexts[request.tag as? Long ?: return] ?: return
            ctx.receivedImages++
            maybeRelease(ctx)
        }
    }

    private fun onJpeg(reader: ImageReader) {
        val img = try { reader.acquireNextImage() } catch (e: Exception) { null } ?: return
        val buf = img.planes[0].buffer
        val bytes = ByteArray(buf.remaining()).also { buf.get(it) }
        val ts = img.timestamp
        img.close()
        val ctx = byTimestamp[ts]
        if (ctx == null) pendingJpeg[ts] = bytes else handleJpeg(ctx, bytes)
    }

    /**
     * Copies the RAW pixels out and returns the buffer to the camera immediately, so the DNG write and
     * development never hold camera buffers (the camera needs them for the next shot).
     */
    private fun onRaw(reader: ImageReader) {
        val img = try { reader.acquireNextImage() } catch (e: Exception) { null } ?: return
        val ts = img.timestamp
        val frame = try { RawDeveloper.copy(img) } finally { img.close() }
        val ctx = byTimestamp[ts]
        if (ctx == null) pendingRaw[ts] = frame else handleRaw(ctx, frame)
    }

    private fun handleJpeg(ctx: CaptureCtx, bytes: ByteArray) {
        ctx.receivedImages++
        ctx.pendingJobs++
        processing.execute {
            try {
                CaptureProcessor.processJpeg(appContext, bytes, ctx.request)
            } finally {
                handler.post { ctx.pendingJobs--; maybeRelease(ctx) }
            }
        }
    }

    private fun handleRaw(ctx: CaptureCtx, frame: RawDeveloper.RawFrame) {
        ctx.receivedImages++
        ctx.rawFrame = frame
        maybeProcessRaw(ctx)
    }

    private fun maybeProcessRaw(ctx: CaptureCtx) {
        val frame = ctx.rawFrame ?: return
        val result = ctx.result ?: return
        if (ctx.rawStarted) return
        ctx.rawStarted = true
        ctx.pendingJobs++
        val c = dngCharacteristics(result)
        val req = ctx.request
        processing.execute {
            try {
                if (req.saveDng) {
                    try {
                        CaptureProcessor.saveDng(appContext, c, result, frame, req)
                    } catch (e: Throwable) {
                        Log.e(TAG, "dng", e)
                    }
                }
                if (req.developRaw) CaptureProcessor.developRaw(appContext, frame, c, result, req)
            } finally {
                handler.post { ctx.rawFrame = null; ctx.pendingJobs--; maybeRelease(ctx) }
            }
        }
    }

    /** For logical multi-cameras, use the physical camera that actually produced the RAW frame. */
    private fun dngCharacteristics(result: CaptureResult): CameraCharacteristics {
        val base = chars!!
        if (Build.VERSION.SDK_INT >= 29) {
            val phys = result.get(CaptureResult.LOGICAL_MULTI_CAMERA_ACTIVE_PHYSICAL_ID)
            if (phys != null) runCatching { return manager.getCameraCharacteristics(phys) }
        }
        return base
    }

    private fun maybeRelease(ctx: CaptureCtx) {
        if (ctx.released) return
        if (!ctx.captureFinished || ctx.pendingJobs > 0 || ctx.receivedImages < ctx.expectedImages) return
        if (ctx.rawFrame != null && !ctx.rawStarted) return
        ctx.released = true
        contexts.remove(ctx.id)
        if (ctx.timestamp >= 0) byTimestamp.remove(ctx.timestamp)
        Log.d(TAG, "capture #${ctx.id} released")
        events.onBufferReleased()
    }

    private fun failOutstanding() {
        pendingRaw.clear()
        pendingJpeg.clear()
        for (ctx in contexts.values.toList()) {
            if (ctx.released) continue
            if (ctx.pendingJobs > 0) {
                // Processing threads will finish them; make sure they can be released afterwards.
                if (!ctx.captureFinished) { ctx.captureFinished = true; events.onSensorReleased(null) }
                ctx.receivedImages = ctx.expectedImages
                continue
            }
            run {
                ctx.released = true
                ctx.rawFrame = null
                contexts.remove(ctx.id)
                if (!ctx.captureFinished) events.onCaptureFailed() else events.onBufferReleased()
            }
        }
        byTimestamp.clear()
    }

    companion object {
        private const val TAG = "CameraController"
        private const val CAPTURE_TIMEOUT_MS = 10_000L
    }
}
