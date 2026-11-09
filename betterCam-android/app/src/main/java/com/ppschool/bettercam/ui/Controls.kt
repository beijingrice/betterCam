package com.ppschool.bettercam.ui

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PointMode
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.ppschool.bettercam.CameraModel
import com.ppschool.bettercam.camera.Haptics
import com.ppschool.bettercam.data.UIWidgets
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

/** ControlDialView.swift */
@Composable
fun ControlDial(model: CameraModel, dialSize: Dp, verticalSpacing: Dp, modifier: Modifier = Modifier) {
    Column(
        modifier,
        verticalArrangement = Arrangement.spacedBy(verticalSpacing),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        KnurledDial(model, dialSize)
        ShutterButton(model)
    }
}

/** KnurledDialView.swift */
@Composable
fun KnurledDial(model: CameraModel, dialSize: Dp) {
    var rotation by remember { mutableFloatStateOf(0f) }
    var accumulator by remember { mutableFloatStateOf(0f) }
    val shown by animateFloatAsState(
        rotation, spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessHigh * 4), label = "dial"
    )
    val step by rememberUpdatedState(if (model.activeIndex == UIWidgets.LENS_SWITCH) 90f else 45f)
    val currentModel by rememberUpdatedState(model)

    Box(
        Modifier
            .size(dialSize)
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val cx = size.width / 2f
                    val cy = size.height / 2f
                    var last = atan2(down.position.y - cy, down.position.x - cx)
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        val angle = atan2(change.position.y - cy, change.position.x - cx)
                        var delta = angle - last
                        if (delta > PI) delta -= (2 * PI).toFloat()
                        if (delta < -PI) delta += (2 * PI).toFloat()
                        last = angle
                        val deg = delta * 180f / PI.toFloat()
                        rotation += deg
                        accumulator += deg
                        if (abs(accumulator) >= step) {
                            currentModel.haptics.impact(Haptics.Style.LIGHT)
                            currentModel.changeParameter(if (accumulator > 0) 1 else -1)
                            accumulator %= step
                        }
                        change.consume()
                    }
                }
            }
    ) {
        // 1. physical shadow
        Canvas(Modifier.matchParentSize().offset(1.dp, 1.dp).blur(2.dp)) {
            drawCircle(Color.Black.copy(alpha = 0.4f))
        }
        // 2. knurled body (pre-rendered once, then rotated)
        Box(
            Modifier
                .matchParentSize()
                .graphicsLayer { rotationZ = shown }
                .drawWithCache {
                    val bitmap = renderKnurl(size, density)
                    onDrawBehind { drawImage(bitmap) }
                }
        )
        Canvas(Modifier.matchParentSize()) {
            drawCircle(Color.White.copy(alpha = 0.12f), style = Stroke(0.5.dp.toPx()))
        }
        // 4. centre cap
        Box(
            Modifier
                .align(Alignment.Center)
                .size(55.dp)
                .clip(CircleShape)
                .background(BodyBase)
                .border(0.8.dp, Color.Black.copy(alpha = 0.4f), CircleShape)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                    currentModel.toggleAdjustmentMode()
                }
        )
    }
}

private fun renderKnurl(size: Size, density: Float): ImageBitmap {
    val w = size.width.toInt().coerceAtLeast(1)
    val h = size.height.toInt().coerceAtLeast(1)
    val image = ImageBitmap(w, h)
    val scope = CanvasDrawScope()
    scope.draw(androidx.compose.ui.unit.Density(density), LayoutDirection.Ltr, Canvas(image), size) {
        val circle = Path().apply { addOval(androidx.compose.ui.geometry.Rect(Offset.Zero, size)) }
        clipPath(circle) { drawKnurl(density) }
    }
    return image
}

private fun DrawScope.drawKnurl(density: Float) {
    val c = center
    val full = size.width / 2f
    drawCircle(BodyBase)
    drawCircle(
        Brush.linearGradient(
            listOf(Color.White.copy(alpha = 0.18f), Color.Transparent, Color.Black.copy(alpha = 0.25f)),
            start = Offset.Zero, end = Offset(size.width, size.height)
        )
    )
    // Pyramid knurl: rings of rotated squares with alternating highlights.
    val outer = full * 0.85f
    val inner = full * 0.45f
    val dot = 4.2f * density
    val bright = Color.White.copy(alpha = 0.3f)
    val dark = Color.Black.copy(alpha = 0.35f)
    for (ring in 0 until 6) {
        val r = inner + ring * (outer - inner) / 4f
        val teeth = (2 * PI * r / (dot * 1.6f)).toInt()
        for (i in 0 until teeth) {
            val angleDeg = i * (360.0 / teeth)
            val rad = angleDeg * PI / 180.0
            val x = c.x + (cos(rad) * r).toFloat()
            val y = c.y + (sin(rad) * r).toFloat()
            rotate((angleDeg + 45.0).toFloat(), Offset(x, y)) {
                drawRect(
                    if ((i + ring) % 2 == 0) bright else dark,
                    topLeft = Offset(x - dot / 2, y - dot / 2), size = Size(dot, dot)
                )
            }
        }
    }
    // Grain specks.
    val rnd = Random(7)
    val pts = List(5000) { Offset(rnd.nextFloat() * size.width, rnd.nextFloat() * size.height) }
    drawPoints(pts, PointMode.Points, Color.Black.copy(alpha = 0.12f), strokeWidth = 0.5f * density)
}

/** ShutterButtonView.swift */
@Composable
fun ShutterButton(model: CameraModel) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.96f else 1f, spring(dampingRatio = 0.5f, stiffness = 990f), label = "press")
    val sink by animateFloatAsState(if (pressed) 1f else 0f, spring(dampingRatio = 0.5f, stiffness = 990f), label = "sink")
    Box(Modifier.size(70.dp)) {
        Canvas(Modifier.matchParentSize().offset(1.dp, 1.dp).blur(2.dp)) {
            drawCircle(Color.Black.copy(alpha = 0.4f))
        }
        Box(
            Modifier
                .matchParentSize()
                .graphicsLayer {
                    scaleX = scale; scaleY = scale
                    translationY = sink * density
                }
                .clip(CircleShape)
                .drawWithCache {
                    val rnd = Random(11)
                    val specks = List(1500) { Offset(rnd.nextFloat() * size.width, rnd.nextFloat() * size.height) }
                    val metal = Brush.linearGradient(
                        listOf(Color(0.6f, 0.6f, 0.6f), Color(0.3f, 0.3f, 0.3f)),
                        start = Offset.Zero, end = Offset(size.width, size.height)
                    )
                    val bevel = Brush.linearGradient(
                        listOf(Color.White.copy(alpha = 0.5f), Color.Transparent, Color.Black.copy(alpha = 0.3f)),
                        start = Offset.Zero, end = Offset(size.width, size.height)
                    )
                    onDrawBehind {
                        drawCircle(metal)
                        var r = size.width / 2f
                        val ring = Stroke(0.5f * density)
                        while (r > 0f) {
                            drawCircle(Color.White.copy(alpha = 0.05f), radius = r, style = ring, blendMode = BlendMode.Overlay)
                            r -= density
                        }
                        drawPoints(specks, PointMode.Points, Color.Black.copy(alpha = 0.1f), strokeWidth = 0.5f * density, blendMode = BlendMode.Overlay)
                        drawCircle(bevel, radius = size.width / 2f - 0.75f * density, style = Stroke(1.5f * density))
                    }
                }
                .clickable(interactionSource = interaction, indication = null) { model.takePhoto() }
        )
    }
}
