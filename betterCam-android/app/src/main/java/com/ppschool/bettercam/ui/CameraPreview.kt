package com.ppschool.bettercam.ui

import android.content.Intent
import android.graphics.SurfaceTexture
import android.net.Uri
import android.provider.Settings
import android.view.TextureView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.ppschool.bettercam.CameraModel
import com.ppschool.bettercam.R
import com.ppschool.bettercam.data.CameraPermissionStatus
import com.ppschool.bettercam.data.ExposureMode
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/** CameraPreview.swift */
@Composable
fun CameraPreview(model: CameraModel) {
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when {
            model.currentLens == null -> Icon(
                painterResource(R.drawable.ic_camera), contentDescription = stringResource(R.string.camera_unavailable),
                tint = Color.Gray, modifier = Modifier.align(Alignment.Center).size(28.dp)
            )
            model.isFullyAuthorized -> ActualPreview(model)
            model.cameraPermission == CameraPermissionStatus.DENIED -> PermissionDeniedView(model)
            else -> Unit
        }
    }
}

@Composable
private fun ActualPreview(model: CameraModel) {
    var showHud by remember { mutableStateOf(false) }
    var hudText by remember { mutableStateOf("") }
    var hudGeneration by remember { mutableIntStateOf(0) }
    var focusPoint by remember { mutableStateOf<Offset?>(null) }
    var focusGeneration by remember { mutableIntStateOf(0) }
    val blur by animateDpAsState(if (model.isSwitchingLens) 30.dp else 0.dp, tween(300), label = "lensBlur")
    val hudFormat = stringResource(R.string.lut_hud_format)
    val currentModel by rememberUpdatedState(model)

    LaunchedEffect(hudGeneration) {
        if (hudGeneration > 0) { delay(500); showHud = false }
    }
    LaunchedEffect(focusGeneration) {
        if (focusGeneration > 0) { delay(1500); focusPoint = null }
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { ctx ->
                TextureView(ctx).apply {
                    surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                        override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) =
                            currentModel.renderer.attachWindow(st, w, h)

                        override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) =
                            currentModel.renderer.resizeWindow(w, h)

                        override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                            currentModel.renderer.detachWindow()
                            return true
                        }

                        override fun onSurfaceTextureUpdated(st: SurfaceTexture) = Unit
                    }
                }
            },
            modifier = Modifier.fillMaxSize().then(if (blur > 0.dp) Modifier.blur(blur) else Modifier),
        )

        Box(
            Modifier.fillMaxSize().padding(bottom = 40.dp),
            contentAlignment = Alignment.BottomEnd,
        ) { ExposureIndicatorOverlay(model) }

        // Gesture layer: swipe for profile intensity / grain, tap to focus.
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectDragGestures(
                        onDragEnd = { hudGeneration++ },
                        onDragCancel = { hudGeneration++ },
                    ) { change, drag ->
                        change.consume()
                        val m = currentModel
                        m.lutIntensity = (m.lutIntensity + drag.x / size.width).coerceIn(0f, 1f)
                        m.grainIntensity = (m.grainIntensity - drag.y / size.height).coerceIn(0f, 1f)
                        hudText = String.format(hudFormat, m.lutIntensity * 100f, m.grainIntensity * 100f)
                        showHud = true
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures { p ->
                        focusPoint = p
                        focusGeneration++
                        currentModel.focusAtView(p.x / size.width, p.y / size.height)
                    }
                }
        )

        AnimatedVisibility(showHud, Modifier.align(Alignment.Center), enter = fadeIn(), exit = fadeOut()) {
            Text(
                hudText,
                color = Color.White,
                fontFamily = FontFamily.Monospace,
                fontSize = fixedSp(12.dp),
                modifier = Modifier
                    .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                    .padding(8.dp),
            )
        }

        focusPoint?.let { p ->
            val boxPx = with(LocalDensity.current) { 70.dp.toPx() }
            FocusBox(
                key = focusGeneration,
                modifier = Modifier.offset { IntOffset((p.x - boxPx / 2).roundToInt(), (p.y - boxPx / 2).roundToInt()) }
            )
        }
    }
}

/** FocusBoxView.swift */
@Composable
private fun FocusBox(key: Int, modifier: Modifier) {
    val anim = remember(key) { Animatable(0f) }
    LaunchedEffect(key) { anim.animateTo(1f, spring(dampingRatio = 0.7f, stiffness = 320f)) }
    Canvas(
        modifier
            .size(70.dp)
            .graphicsLayer {
                val s = 1.4f - 0.4f * anim.value
                scaleX = s; scaleY = s; alpha = anim.value.coerceIn(0f, 1f)
            }
    ) {
        val lw = 1.2.dp.toPx()
        val green = Color(0xFF34C759)
        drawRect(green, style = Stroke(lw))
        drawRect(green, topLeft = Offset(0f, size.height / 2 - lw / 2), size = Size(size.width, lw))
        drawRect(green, topLeft = Offset(size.width / 2 - lw / 2, 0f), size = Size(lw, size.height))
    }
}

/** WaveformOverlay.swift + HistogramOverlay.swift */
@Composable
private fun ExposureIndicatorOverlay(model: CameraModel) {
    val mode = model.exposureIndicatorMode
    val image = model.indicatorImage ?: return
    if (mode == ExposureMode.OFF) return
    val w = model.overlayWidth.dp
    val h = model.overlayHeight.dp
    Box(
        Modifier
            .size(w, h)
            .clip(RoundedCornerShape(4.dp))
            .background(Color.Black.copy(alpha = 0.5f))
            .border(0.5.dp, Color.White.copy(alpha = 0.2f), RoundedCornerShape(4.dp))
    ) {
        Image(image, contentDescription = null, contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
        Canvas(Modifier.fillMaxSize()) {
            val strong = Color.White.copy(alpha = 0.2f)
            val weak = Color.White.copy(alpha = 0.1f)
            val px = 1.dp.toPx()
            if (mode == ExposureMode.WAVEFORM) {
                drawRect(strong, Offset(0f, 0f), Size(size.width, px))
                drawRect(weak, Offset(0f, size.height / 2), Size(size.width, px))
                drawRect(strong, Offset(0f, size.height - px), Size(size.width, px))
            } else {
                drawRect(strong, Offset(0f, 0f), Size(px, size.height))
                drawRect(weak, Offset(size.width / 2, 0f), Size(px, size.height))
                drawRect(strong, Offset(size.width - px, 0f), Size(px, size.height))
            }
        }
    }
}

@Composable
private fun PermissionDeniedView(model: CameraModel) {
    val context = LocalContext.current
    Column(
        Modifier.fillMaxSize().background(Color.Black).padding(vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
    ) {
        Icon(Icons.Filled.Lock, null, tint = Color(0xFFFF9500), modifier = Modifier.size(44.dp))
        Text(stringResource(R.string.permission_needed), color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            PermissionRow(stringResource(R.string.camera_access), model.cameraPermission == CameraPermissionStatus.AUTHORIZED)
            PermissionRow(stringResource(R.string.photo_lib_access), true)
        }
        Button(
            onClick = {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            },
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF0A84FF)),
        ) { Text(stringResource(R.string.open_settings)) }
    }
}

@Composable
private fun PermissionRow(label: String, granted: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            if (granted) Icons.Filled.CheckCircle else Icons.Filled.Close, null,
            tint = if (granted) Color(0xFF34C759) else Color(0xFFFF3B30), modifier = Modifier.size(18.dp)
        )
        Spacer(Modifier.width(8.dp))
        Text(label, color = Color.White, fontSize = 14.sp)
    }
}
