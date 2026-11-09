package com.ppschool.bettercam.camera

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.OrientationEventListener
import com.ppschool.bettercam.R
import com.ppschool.bettercam.data.ShutterSoundMode

/** MotionManager.swift: tracks how the phone is held so photos get the right orientation. */
class OrientationTracker(context: Context) {
    /** Device rotation in degrees clockwise from natural orientation (0/90/180/270). */
    @Volatile var deviceDegrees: Int = 0
        private set

    private val listener = object : OrientationEventListener(context.applicationContext) {
        override fun onOrientationChanged(orientation: Int) {
            if (orientation == ORIENTATION_UNKNOWN) return
            deviceDegrees = ((orientation + 45) / 90 * 90) % 360
        }
    }

    fun start() { if (listener.canDetectOrientation()) listener.enable() }
    fun stop() = listener.disable()

    fun jpegOrientation(sensorOrientation: Int, front: Boolean): Int {
        val d = if (front) -deviceDegrees else deviceDegrees
        return (sensorOrientation + d + 360) % 360
    }
}

/** ShutterSoundManager.swift */
class ShutterSound(context: Context) {
    private val pool = SoundPool.Builder()
        .setMaxStreams(4)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
        ).build()
    private val ids = mapOf(
        ShutterSoundMode.SONY to pool.load(context, R.raw.shutter_eqed_gained, 1),
        ShutterSoundMode.PANASONIC to pool.load(context, R.raw.s1m2_shutter_gained, 1),
    )
    private var current = ShutterSoundMode.SONY

    fun setup(mode: ShutterSoundMode) { current = mode }
    fun play() { ids[current]?.let { pool.play(it, 1f, 1f, 1, 0, 1f) } }
}

/** UIImpactFeedbackGenerator equivalents. */
class Haptics(context: Context) {
    enum class Style { LIGHT, MEDIUM, HEAVY }

    private val vibrator: Vibrator? =
        (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator

    fun impact(style: Style) {
        val v = vibrator ?: return
        if (!v.hasVibrator()) return
        val effect = when (style) {
            Style.LIGHT -> VibrationEffect.EFFECT_TICK
            Style.MEDIUM -> VibrationEffect.EFFECT_CLICK
            Style.HEAVY -> VibrationEffect.EFFECT_HEAVY_CLICK
        }
        v.vibrate(VibrationEffect.createPredefined(effect))
    }
}
