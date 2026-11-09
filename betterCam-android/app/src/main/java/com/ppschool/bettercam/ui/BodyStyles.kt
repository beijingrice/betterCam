package com.ppschool.bettercam.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ppschool.bettercam.R

/** Camera body metal colour (Color(red: 0.45, green: 0.45, blue: 0.46) on iOS). */
val BodyBase = Color(0.45f, 0.45f, 0.46f)

/** Tiles a 3x grain texture at its point size (512pt) with overlay blending. */
fun DrawScope.drawNoise(image: ImageBitmap, density: Float, blend: BlendMode = BlendMode.Overlay) {
    val shader = ImageShader(image, TileMode.Repeated, TileMode.Repeated)
    val scale = density / 3f
    shader.setLocalMatrix(android.graphics.Matrix().apply { setScale(scale, scale) })
    drawRect(ShaderBrush(shader), blendMode = blend)
}

/** BodyFrameBackground.swift + BodyGrainLayer.swift */
@Composable
fun BodyFrameBackground(modifier: Modifier = Modifier) {
    val noise = ImageBitmap.imageResource(R.drawable.body_noise)
    val density = LocalDensity.current.density
    Canvas(modifier.fillMaxSize()) {
        drawRect(BodyBase)
        drawRect(
            Brush.linearGradient(
                listOf(Color.White.copy(alpha = 0.15f), Color.Transparent, Color.Black.copy(alpha = 0.2f)),
                start = Offset.Zero, end = Offset(size.width, size.height)
            )
        )
        drawRect(
            Brush.radialGradient(
                listOf(Color.White.copy(alpha = 0.5f), Color.Transparent),
                center = Offset.Zero, radius = 700.dp.toPx()
            )
        )
        drawNoise(noise, density)
    }
}

/** wrapInCameraFrame(thickness:): darker grain bezel around the LCD. */
@Composable
fun Modifier.cameraFrame(): Modifier {
    val noise = ImageBitmap.imageResource(R.drawable.body_noise_darker)
    val density = LocalDensity.current.density
    return this.drawBehind {
        drawRect(BodyBase)
        drawRect(
            Brush.linearGradient(
                listOf(Color.White.copy(alpha = 0.08f), Color.Transparent, Color.Black.copy(alpha = 0.1f)),
                start = Offset.Zero, end = Offset(size.width, size.height)
            )
        )
        drawNoise(noise, density)
    }
}

/** recessedPanel(cornerRadius:depth:): sunken edge shading and a lit lower-right bevel. */
fun Modifier.recessedPanel(cornerRadius: Dp = 8.dp, depth: Dp = 2.dp): Modifier = this
    .clip(RoundedCornerShape(cornerRadius))
    .drawWithContent {
        drawContent()
        val r = CornerRadius(cornerRadius.toPx())
        val c = Offset(size.width / 2, size.height / 2)
        drawRoundRect(
            Brush.linearGradient(listOf(Color.Black.copy(alpha = 0.6f), Color.Transparent), start = Offset.Zero, end = c),
            cornerRadius = r, style = Stroke(depth.toPx())
        )
        drawRoundRect(
            Brush.linearGradient(listOf(Color.Black.copy(alpha = 0.8f), Color.Transparent), start = Offset(size.width, 0f), end = c),
            cornerRadius = r, style = Stroke(1.dp.toPx())
        )
        drawRoundRect(
            Brush.linearGradient(listOf(Color.Transparent, Color.White.copy(alpha = 0.5f)), start = c, end = Offset(size.width, size.height)),
            cornerRadius = r, style = Stroke(1.dp.toPx())
        )
    }
