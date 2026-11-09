package com.ppschool.bettercam.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ppschool.bettercam.CameraModel
import com.ppschool.bettercam.R
import com.ppschool.bettercam.camera.Haptics
import com.ppschool.bettercam.data.ExposureMode
import com.ppschool.bettercam.data.ImageQuality
import com.ppschool.bettercam.data.PhotoResolutionMode
import com.ppschool.bettercam.data.ShutterSoundMode

/** MenuView.swift */
@Composable
fun MenuScreen(model: CameraModel) {
    val pm = model.pm
    val enable = stringResource(R.string.enable)
    val disable = stringResource(R.string.disable)
    fun haptic() = model.haptics.impact(Haptics.Style.MEDIUM)

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(30.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Box(Modifier.fillMaxWidth()) {
                Icon(
                    Icons.Filled.Close, contentDescription = stringResource(R.string.close), tint = Color.White,
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .padding(10.dp)
                        .size(26.dp)
                        .clickable(remember { MutableInteractionSource() }, null) { haptic(); model.showMenu(false) }
                )
                Text(
                    stringResource(R.string.settings), color = Color.White, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold, fontSize = fixedSp(16.dp), letterSpacing = 2.sp,
                    modifier = Modifier.align(Alignment.Center)
                )
            }

            Section(stringResource(R.string.exposure_indicator)) {
                Segments {
                    SegmentedButton(stringResource(R.string.waveform), model.exposureIndicatorMode == ExposureMode.WAVEFORM) {
                        haptic(); model.setExposureMode(ExposureMode.WAVEFORM)
                    }
                    SegmentedButton(stringResource(R.string.histogram), model.exposureIndicatorMode == ExposureMode.HISTOGRAM) {
                        haptic(); model.setExposureMode(ExposureMode.HISTOGRAM)
                    }
                    SegmentedButton(stringResource(R.string.off), model.exposureIndicatorMode == ExposureMode.OFF) {
                        haptic(); model.setExposureMode(ExposureMode.OFF)
                    }
                }
            }

            Section(stringResource(R.string.front_camera)) {
                Segments {
                    SegmentedButton(enable, pm.enableFrontCamera) { haptic(); model.setFrontCameraEnabled(true) }
                    SegmentedButton(disable, !pm.enableFrontCamera) { haptic(); model.setFrontCameraEnabled(false) }
                }
            }

            Section(stringResource(R.string.shutter_sound)) {
                Segments {
                    SegmentedButton("1", pm.shutterSoundSelection == ShutterSoundMode.SONY) { haptic(); pm.updateShutterSound(ShutterSoundMode.SONY) }
                    SegmentedButton("2", pm.shutterSoundSelection == ShutterSoundMode.PANASONIC) { haptic(); pm.updateShutterSound(ShutterSoundMode.PANASONIC) }
                }
            }

            Section(stringResource(R.string.save_ss_iso)) {
                Segments {
                    SegmentedButton(enable, pm.enablePermanentStorage, disabled = pm.preferAUTO) {
                        haptic(); pm.updateEnablePermanentStorage(true); pm.saveExposureParameters()
                    }
                    SegmentedButton(disable, !pm.enablePermanentStorage, disabled = pm.preferAUTO) {
                        haptic(); pm.updateEnablePermanentStorage(false)
                    }
                }
            }

            Section(stringResource(R.string.prefer_auto)) {
                Segments {
                    SegmentedButton(enable, pm.preferAUTO) { pm.updatePreferAUTO(true); pm.updateEnablePermanentStorage(false) }
                    SegmentedButton(disable, !pm.preferAUTO) { pm.updatePreferAUTO(false) }
                }
            }

            Section(stringResource(R.string.image_quality)) {
                Segments {
                    for (option in pm.imageQualityOptions) {
                        val disabled = (option == ImageQuality.PRORAW && !model.isProRAWSupported) ||
                            ((option == ImageQuality.DNG || option == ImageQuality.DNG_J) && !model.isRawSupported)
                        SegmentedButton(option, pm.imageQuality == option, disabled = disabled) {
                            haptic(); pm.imageQuality = option
                        }
                    }
                }
            }

            Section(stringResource(R.string.photo_resolution)) {
                Segments {
                    SegmentedButton(
                        model.standardMP?.let { "${it}MP" } ?: "STD N/A",
                        pm.photoResolutionMode == PhotoResolutionMode.STANDARD,
                        disabled = !model.is24MPSupported,
                    ) { haptic(); pm.photoResolutionMode = PhotoResolutionMode.STANDARD }
                    SegmentedButton(
                        model.highMP?.let { "${it}MP" } ?: "HIGH N/A",
                        pm.photoResolutionMode == PhotoResolutionMode.HIGH_48MP,
                        disabled = !model.is48MPSupported,
                    ) { haptic(); pm.photoResolutionMode = PhotoResolutionMode.HIGH_48MP }
                }
                Text(stringResource(R.string.resolution_note), color = Color.Gray, fontSize = 11.sp)
            }

            Section(stringResource(R.string.enable_zero_processing)) {
                Segments {
                    SegmentedButton(enable, pm.isPureRawEngineEnabled, disabled = !model.isRawSupported) {
                        pm.updatePureRawEngine(true); pm.photoResolutionMode = PhotoResolutionMode.STANDARD
                    }
                    SegmentedButton(disable, !pm.isPureRawEngineEnabled) { pm.updatePureRawEngine(false) }
                }
            }

            Spacer(Modifier.height(8.dp))
        }

    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, color = Color.Gray, fontWeight = FontWeight.Bold, fontSize = 12.sp)
        content()
    }
}

@Composable
private fun Segments(content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.1f)),
        content = content,
    )
}

/** SegmentedButton from MenuView.swift */
@Composable
private fun RowScope.SegmentedButton(title: String, selected: Boolean, disabled: Boolean = false, action: () -> Unit) {
    val bg = when {
        disabled -> Color.Black.copy(alpha = 0.4f)
        selected -> Color.White
        else -> Color.Transparent
    }
    val fg = when {
        disabled -> Color.White.copy(alpha = 0.6f)
        selected -> Color.Black
        else -> Color.White
    }
    Box(
        Modifier
            .weight(1f)
            .height(40.dp)
            .background(bg)
            .clickable(enabled = !disabled, interactionSource = remember { MutableInteractionSource() }, indication = null) { action() },
        contentAlignment = Alignment.Center,
    ) {
        AutoShrinkText(title, fg, fixedSp(14.dp), FontWeight.Bold)
    }
}
