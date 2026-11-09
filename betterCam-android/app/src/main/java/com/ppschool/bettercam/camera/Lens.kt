package com.ppschool.bettercam.camera

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.os.Build
import android.util.Log
import android.util.Size
import com.ppschool.bettercam.data.ExposureParameter
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * One selectable "lens". On Android several lenses can map to the same logical camera
 * at different zoom ratios (that is how most phones expose ultra-wide / tele).
 */
data class Lens(
    val key: String,
    val cameraId: String,
    val zoomRatio: Float,
    val equivalentFocalLength: Int,
    val aperture: String,
    val isFront: Boolean,
    val displayName: String?,
    val sensorOrientation: Int,
    val availableSSOptions: List<String>,
    val availableISOOptions: List<String>,
    val minISO: Int,
    val maxISO: Int,
    val minExposureNs: Long,
    val maxExposureNs: Long,
    val supportsManual: Boolean,
    val supportsRaw: Boolean,
    val evStep: Float,
    val evRange: IntRange,
)

object LensDiscovery {
    private const val TAG = "LensDiscovery"

    fun discover(context: Context, enableFront: Boolean): List<Lens> {
        val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val ids = try { cm.cameraIdList.toList() } catch (e: Exception) { emptyList() }
        val chars = ids.associateWith { runCatching { cm.getCameraCharacteristics(it) }.getOrNull() }
        val backs = ids.filter { chars[it]?.get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_BACK }
        val fronts = ids.filter { chars[it]?.get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_FRONT }

        val lenses = mutableListOf<Lens>()
        val primary = backs.firstOrNull()
        if (primary != null) {
            val pc = chars[primary]!!
            val mainEq = equivalentFocal(pc)
            lenses += makeLens(primary, pc, 1f, mainEq, null, apertureFrom(pc))

            val zoomRange = if (Build.VERSION.SDK_INT >= 30) pc.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) else null
            val caps = pc.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
            val isLogical = caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)
            if (zoomRange != null && isLogical && mainEq > 0f) {
                for (phys in pc.physicalCameraIds) {
                    val phc = runCatching { cm.getCameraCharacteristics(phys) }.getOrNull() ?: continue
                    val eq = equivalentFocal(phc)
                    if (eq <= 0f) continue
                    val ratio = (eq / mainEq).coerceIn(zoomRange.lower, zoomRange.upper)
                    if (abs(ratio - 1f) < 0.15f) continue
                    val actualEq = mainEq * ratio
                    if (lenses.any { abs(it.equivalentFocalLength - actualEq) < 3f }) continue
                    lenses += makeLens(primary, pc, ratio, actualEq, null, apertureFrom(phc))
                }
            }
            // Devices that expose extra back cameras as standalone IDs.
            for (id in backs.drop(1)) {
                val c = chars[id] ?: continue
                val eq = equivalentFocal(c)
                if (eq <= 0f || lenses.any { abs(it.equivalentFocalLength - eq) < 3f }) continue
                val caps2 = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
                if (!caps2.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE)) continue
                lenses += makeLens(id, c, 1f, eq, null, apertureFrom(c))
            }
        }
        lenses.sortBy { it.equivalentFocalLength }

        if (enableFront) {
            fronts.firstOrNull()?.let { id ->
                val c = chars[id]!!
                lenses.add(0, makeLens(id, c, 1f, equivalentFocal(c), "FRONT", apertureFrom(c)))
            }
        }
        Log.i(TAG, "lenses: " + lenses.joinToString { "${it.cameraId}@${it.zoomRatio}=${it.equivalentFocalLength}mm" })
        return lenses
    }

    fun defaultLens(lenses: List<Lens>): Lens? =
        lenses.firstOrNull { !it.isFront && it.zoomRatio == 1f } ?: lenses.firstOrNull()

    private fun apertureFrom(c: CameraCharacteristics): String {
        val a = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)?.firstOrNull() ?: 0f
        return String.format(java.util.Locale.US, "F%.1f", if (a > 0) a else 1.8f)
    }

    /** 35mm-equivalent focal length using the sensor diagonal. */
    private fun equivalentFocal(c: CameraCharacteristics): Float {
        val f = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: return 0f
        val size = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return 0f
        val diag = sqrt(size.width * size.width + size.height * size.height)
        if (diag <= 0f) return 0f
        return f * 43.27f / diag
    }

    private fun makeLens(
        id: String, c: CameraCharacteristics, zoom: Float, eq: Float, displayName: String?, aperture: String,
    ): Lens {
        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
        val manual = caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
        val raw = caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_RAW) &&
            (c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(ImageFormat.RAW_SENSOR)?.isNotEmpty() == true)
        val isoRange = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val expRange = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val minIso = isoRange?.lower ?: 100
        val maxIso = isoRange?.upper ?: 3200
        val minNs = expRange?.lower ?: 100_000L
        val maxNs = expRange?.upper ?: 1_000_000_000L
        val ss = if (manual) ExposureParameter.supportedSS(minNs, maxNs) else listOf(ExposureParameter.AUTO)
        val iso = if (manual) ExposureParameter.supportedISO(minIso, maxIso) else listOf(ExposureParameter.AUTO)
        val numeric = iso.mapNotNull { ExposureParameter.isoValue(it)?.toInt() }
        val evStep = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toFloat() ?: (1f / 3f)
        val evRange = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)?.let { it.lower..it.upper } ?: 0..0
        val front = c.get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_FRONT
        return Lens(
            key = "$id@$zoom",
            cameraId = id,
            zoomRatio = zoom,
            equivalentFocalLength = eq.roundToInt(),
            aperture = aperture,
            isFront = front,
            displayName = displayName,
            sensorOrientation = c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90,
            availableSSOptions = ss,
            availableISOOptions = iso,
            minISO = numeric.minOrNull() ?: minIso,
            maxISO = numeric.maxOrNull() ?: maxIso,
            minExposureNs = minNs,
            maxExposureNs = maxNs,
            supportsManual = manual,
            supportsRaw = raw,
            evStep = evStep,
            evRange = evRange,
        )
    }
}

/** Port of PhotoDimensions.swift: picks 12/24/48 MP capture sizes from what the sensor supports. */
class PhotoDimensions(supported: List<Size>, maxResSupported: List<Size> = emptyList()) {
    val nativeRAW: Size?
    val medium: Size?
    val high: Size?
    /** True when [high] needs SENSOR_PIXEL_MODE_MAXIMUM_RESOLUTION (quad-bayer full readout). */
    val highNeedsMaxResolution: Boolean

    init {
        fun px(s: Size) = s.width.toLong() * s.height
        fun closest(list: List<Size>, target: Long) = list.minByOrNull { abs(px(it) - target) }
        val fourThree = supported.filter { abs(it.width.toFloat() / it.height - 4f / 3f) < 0.02f }.ifEmpty { supported }
        nativeRAW = closest(fourThree, 12_000_000)
        medium = closest(fourThree, 24_000_000)?.takeIf { px(it) in 18_000_000 until 40_000_000 }
        val regularHigh = closest(fourThree, 48_000_000)?.takeIf { px(it) >= 40_000_000 }
        if (regularHigh != null) {
            high = regularHigh
            highNeedsMaxResolution = false
        } else {
            val mr = maxResSupported.filter { abs(it.width.toFloat() / it.height - 4f / 3f) < 0.02f }.ifEmpty { maxResSupported }
            high = closest(mr, 48_000_000)?.takeIf { px(it) >= 40_000_000 }
            highNeedsMaxResolution = high != null
        }
    }

    val standard: Size? get() = medium ?: nativeRAW
}
