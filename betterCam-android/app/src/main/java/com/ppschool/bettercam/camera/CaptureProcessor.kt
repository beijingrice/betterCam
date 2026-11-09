package com.ppschool.bettercam.camera

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.DngCreator
import android.media.Image
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import com.ppschool.bettercam.engine.FilmEngine
import java.io.File
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

/** Everything a still capture needs, frozen at shutter time (PhotoCaptureRequest.swift). */
data class PhotoCaptureRequest(
    val imageQuality: String,
    val highResolution: Boolean,
    val isFrontCamera: Boolean,
    val usePureRawEngine: Boolean,
    val styleName: String,
    val lutIntensity: Float,
    val grainIntensity: Float,
    val usesManualExposure: Boolean,
    val manualExposureNs: Long?,
    val manualISO: Int?,
    val jpegOrientation: Int,
) {
    val saveDng get() = imageQuality == "DNG" || imageQuality == "DNG+J"
    val developRaw get() = usePureRawEngine && imageQuality != "DNG"
    val needsRaw get() = saveDng || developRaw
    val needsJpeg get() = !developRaw && imageQuality != "DNG"

    /** EXIF orientation including the selfie mirror that iOS applies to front-camera photos. */
    val exifOrientation: Int
        get() {
            val base = when (jpegOrientation) {
                90 -> ExifInterface.ORIENTATION_ROTATE_90
                180 -> ExifInterface.ORIENTATION_ROTATE_180
                270 -> ExifInterface.ORIENTATION_ROTATE_270
                else -> ExifInterface.ORIENTATION_NORMAL
            }
            return if (isFrontCamera) mirrored(base) else base
        }

    companion object {
        fun mirrored(o: Int) = when (o) {
            ExifInterface.ORIENTATION_NORMAL, ExifInterface.ORIENTATION_UNDEFINED -> ExifInterface.ORIENTATION_FLIP_HORIZONTAL
            ExifInterface.ORIENTATION_ROTATE_180 -> ExifInterface.ORIENTATION_FLIP_VERTICAL
            ExifInterface.ORIENTATION_ROTATE_90 -> ExifInterface.ORIENTATION_TRANSPOSE
            ExifInterface.ORIENTATION_ROTATE_270 -> ExifInterface.ORIENTATION_TRANSVERSE
            else -> o
        }
    }
}

/** Develops and saves captured frames (the processing half of SessionManager.swift). */
object CaptureProcessor {
    private const val TAG = "CaptureProcessor"
    private const val ALBUM = "DCIM/betterCam"
    private val counter = AtomicInteger()

    private val exifTags: List<String> by lazy {
        val skip = setOf(
            ExifInterface.TAG_IMAGE_WIDTH, ExifInterface.TAG_IMAGE_LENGTH,
            ExifInterface.TAG_PIXEL_X_DIMENSION, ExifInterface.TAG_PIXEL_Y_DIMENSION,
            ExifInterface.TAG_JPEG_INTERCHANGE_FORMAT, ExifInterface.TAG_JPEG_INTERCHANGE_FORMAT_LENGTH,
            ExifInterface.TAG_THUMBNAIL_IMAGE_LENGTH, ExifInterface.TAG_THUMBNAIL_IMAGE_WIDTH,
            ExifInterface.TAG_THUMBNAIL_ORIENTATION, ExifInterface.TAG_COMPRESSION,
            ExifInterface.TAG_STRIP_OFFSETS, ExifInterface.TAG_STRIP_BYTE_COUNTS,
            ExifInterface.TAG_BITS_PER_SAMPLE, ExifInterface.TAG_SAMPLES_PER_PIXEL,
            ExifInterface.TAG_PHOTOMETRIC_INTERPRETATION,
        )
        ExifInterface::class.java.fields
            .filter { it.name.startsWith("TAG_") && it.type == String::class.java }
            .mapNotNull { runCatching { it.get(null) as String }.getOrNull() }
            .filter { it !in skip }
            .distinct()
    }

    private fun baseName(): String =
        "BC_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + "_" + (counter.incrementAndGet() % 1000)

    // ------------------------------------------------------------- JPEG path

    fun processJpeg(context: Context, jpeg: ByteArray, req: PhotoCaptureRequest) {
        val plan = FilmEngine.plan(req.styleName, req.lutIntensity, req.grainIntensity)
        val cache = context.cacheDir
        val original = File(cache, "orig_${System.nanoTime()}.jpg").apply { writeBytes(jpeg) }
        try {
            val out: File
            if (plan.isIdentity) {
                out = original
            } else {
                val opts = BitmapFactory.Options().apply {
                    inMutable = true
                    inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
                }
                val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, opts) ?: return
                FilmEngine.processBitmap(bmp, plan)
                out = File(cache, "film_${System.nanoTime()}.jpg")
                out.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                bmp.recycle()
                copyExif(original, out)
            }
            if (req.isFrontCamera) {
                val exif = ExifInterface(out)
                val o = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                exif.setAttribute(ExifInterface.TAG_ORIENTATION, PhotoCaptureRequest.mirrored(o).toString())
                exif.saveAttributes()
            }
            saveFile(context, out, baseName() + ".jpg", "image/jpeg")
            if (out != original) out.delete()
        } catch (e: Throwable) {
            Log.e(TAG, "JPEG processing failed", e)
        } finally {
            original.delete()
        }
    }

    private fun copyExif(from: File, to: File) {
        try {
            val src = ExifInterface(from)
            val dst = ExifInterface(to)
            for (tag in exifTags) src.getAttribute(tag)?.let { dst.setAttribute(tag, it) }
            dst.saveAttributes()
        } catch (e: Exception) {
            Log.w(TAG, "EXIF copy failed", e)
        }
    }

    // ------------------------------------------------------------- RAW path

    fun saveDng(context: Context, chars: CameraCharacteristics, result: CaptureResult, image: Image, req: PhotoCaptureRequest) {
        try {
            val creator = DngCreator(chars, result)
            creator.setOrientation(req.exifOrientation)
            insert(context, baseName() + ".dng", "image/x-adobe-dng") { creator.writeImage(it, image) }
            creator.close()
        } catch (e: Throwable) {
            Log.e(TAG, "DNG save failed", e)
        }
    }

    fun developRaw(
        context: Context, frame: RawDeveloper.RawFrame, chars: CameraCharacteristics,
        result: CaptureResult, req: PhotoCaptureRequest,
    ) {
        try {
            val bmp = RawDeveloper.develop(frame, chars, result) ?: return
            FilmEngine.processBitmap(bmp, FilmEngine.plan(req.styleName, req.lutIntensity, req.grainIntensity))
            val out = File(context.cacheDir, "raw_${System.nanoTime()}.jpg")
            out.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 95, it) }
            bmp.recycle()
            val exif = ExifInterface(out)
            exif.setAttribute(ExifInterface.TAG_ORIENTATION, req.exifOrientation.toString())
            exif.setAttribute(ExifInterface.TAG_MAKE, Build.MANUFACTURER)
            exif.setAttribute(ExifInterface.TAG_MODEL, Build.MODEL)
            exif.setAttribute(ExifInterface.TAG_SOFTWARE, "betterCam ZERO PROCESSING")
            val now = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US).format(Date())
            exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, now)
            exif.setAttribute(ExifInterface.TAG_DATETIME, now)
            result.get(CaptureResult.SENSOR_SENSITIVITY)?.let {
                exif.setAttribute(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, it.toString())
            }
            result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let {
                exif.setAttribute(ExifInterface.TAG_EXPOSURE_TIME, (it / 1e9).toString())
            }
            result.get(CaptureResult.LENS_FOCAL_LENGTH)?.let {
                exif.setAttribute(ExifInterface.TAG_FOCAL_LENGTH, "${(it * 1000).toInt()}/1000")
            }
            result.get(CaptureResult.LENS_APERTURE)?.let {
                exif.setAttribute(ExifInterface.TAG_F_NUMBER, it.toString())
            }
            exif.saveAttributes()
            saveFile(context, out, baseName() + ".jpg", "image/jpeg")
            out.delete()
        } catch (e: Throwable) {
            Log.e(TAG, "RAW development failed", e)
        }
    }

    // ------------------------------------------------------------- MediaStore

    private fun saveFile(context: Context, file: File, name: String, mime: String) {
        insert(context, name, mime) { os -> file.inputStream().use { it.copyTo(os) } }
    }

    private fun insert(context: Context, name: String, mime: String, write: (OutputStream) -> Unit): Uri? {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, ALBUM)
            put(MediaStore.Images.Media.DATE_TAKEN, System.currentTimeMillis())
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: return null.also { Log.e(TAG, "insert failed for $name") }
        try {
            resolver.openOutputStream(uri)?.use(write)
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            Log.i(TAG, "saved $name")
            return uri
        } catch (e: Throwable) {
            resolver.delete(uri, null, null)
            throw e
        }
    }
}
