package com.ppschool.bettercam.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import com.ppschool.bettercam.CameraModel
import kotlin.math.max
import kotlin.math.min

private enum class Page { CAMERA, MENU, LUTS }

/** ContentView.swift */
@Composable
fun BetterCamRoot(model: CameraModel) {
    val page = when {
        model.isShowingMenu -> Page.MENU
        !model.inCameraView -> Page.LUTS
        else -> Page.CAMERA
    }
    // Android Back closes the menu / LUT manager instead of leaving the app.
    BackHandler(enabled = page != Page.CAMERA) {
        if (page == Page.MENU) model.showMenu(false) else model.showCameraView(true)
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AnimatedVisibility(page == Page.CAMERA, enter = fadeIn(tween(240)), exit = fadeOut(tween(240))) {
            BodyFrameBackground()
        }
        LandscapeWorkspace(onTurns = { model.displayTurns = it }) { size, turns ->
            AnimatedContent(
                targetState = page,
                transitionSpec = {
                    val enter = if (targetState == Page.CAMERA) fadeIn(tween(240))
                    else fadeIn(tween(240)) + slideInVertically(tween(240)) { 8 }
                    enter togetherWith fadeOut(tween(240))
                },
                label = "page",
            ) { p ->
                when (p) {
                    Page.MENU -> MenuScreen(model)
                    Page.LUTS -> LutManagerScreen(model)
                    Page.CAMERA -> CameraBody(model, size, turns)
                }
            }
        }
    }
}

/**
 * LandscapeWorkspace.swift: the app is locked to the device's natural orientation and the
 * whole UI is laid out in landscape, then rotated a quarter turn on portrait screens.
 */
@Composable
fun LandscapeWorkspace(onTurns: (Int) -> Unit, content: @Composable (DpSize, Int) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.displayCutout)) {
        val swap = maxHeight > maxWidth
        val turns = if (swap) 1 else 0
        val w = if (swap) maxHeight else maxWidth
        val h = if (swap) maxWidth else maxHeight
        SideEffect { onTurns(turns) }
        Box(
            Modifier
                .align(Alignment.Center)
                .requiredSize(w, h)
                .graphicsLayer { rotationZ = turns * 90f }
        ) {
            content(DpSize(w, h), turns)
        }
    }
}

/** ContentView.cameraBody(size:turns:display:) */
@Composable
private fun CameraBody(model: CameraModel, size: DpSize, turns: Int) {
    val w = size.width.value
    val h = size.height.value
    val sideMargin = 8f
    val verticalMargin = 8f
    val bezel = 8f
    val gripGap = min(32f, w * 0.035f)
    val dialSize = min(140f, max(96f, w * 0.16f))
    val lcdWidth = max(0f, min(w - 2 * (sideMargin + bezel) - gripGap - dialSize, (h - 2 * (verticalMargin + bezel)) * 4f / 3f))
    val bodyWidth = lcdWidth + 2 * bezel + gripGap + dialSize
    val gripOffset = if (turns != 0) min(8f, max(0f, (w - bodyWidth) / 2 - 4)) else 0f
    val spacing = min(60f, max(8f, h - 2 * verticalMargin - dialSize - 70f))

    Row(
        Modifier.fillMaxSize(),
        horizontalArrangement = Arrangement.spacedBy(gripGap.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .recessedPanel()
                .cameraFrame()
                .padding(bezel.dp)
        ) {
            Box(Modifier.size(lcdWidth.dp, (lcdWidth * 3f / 4f).dp)) {
                ScreenView(model)
                if (model.isShowingTutorial) TutorialOverlay(model)
            }
        }
        ControlDial(model, dialSize.dp, spacing.dp, Modifier.offset(x = gripOffset.dp))
    }
}
