package com.ppschool.bettercam.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import com.ppschool.bettercam.CameraModel
import com.ppschool.bettercam.data.UIWidgets

/** Fixed-size text (camera UI ignores system font scaling, like the iOS fixed point sizes). */
@Composable
fun fixedSp(size: Dp): TextUnit = with(LocalDensity.current) { size.toSp() }

/** ScreenView.swift: the 4:3 LCD with the preview and the two parameter bars. */
@Composable
fun ScreenView(model: CameraModel) {
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        CameraPreview(model)
        if (model.currentLens == null || model.isFullyAuthorized) {
            Column(Modifier.fillMaxSize()) {
                TopBar(model)
                Spacer(Modifier.weight(1f))
                BottomBar(model)
            }
        }
    }
}

@Composable
private fun TopBar(model: CameraModel) {
    val pm = model.pm
    val lens = model.currentLens
    ParameterBar(fontSize = fixedSp(14.dp), weight = FontWeight.Bold) {
        ParameterItem(model, pm.imageQuality, UIWidgets.IMAGE_QUALITY)
        ParameterItem(model, lens?.let { it.displayName ?: "${it.equivalentFocalLength}mm" } ?: "-", UIWidgets.LENS_SWITCH)
        ParameterItem(model, pm.afMode, UIWidgets.AF_MODE)
        ParameterItem(model, pm.wbMode, UIWidgets.WB_MODE)
        ParameterItem(model, "MENU", UIWidgets.MENU)
    }
}

@Composable
private fun BottomBar(model: CameraModel) {
    val pm = model.pm
    ParameterBar(fontSize = fixedSp(16.dp), weight = FontWeight.Medium) {
        ParameterItem(model, pm.ss, UIWidgets.SS)
        ParameterItem(model, pm.aperture, UIWidgets.APERTURE)
        ParameterItem(model, pm.ev, UIWidgets.EV)
        ParameterItem(model, pm.iso, UIWidgets.ISO)
        ParameterItem(model, pm.style, UIWidgets.STYLE)
    }
}

private data class BarStyle(val fontSize: TextUnit, val weight: FontWeight)

private val LocalBarStyle = androidx.compose.runtime.staticCompositionLocalOf { BarStyle(TextUnit.Unspecified, FontWeight.Bold) }

@Composable
private fun ParameterBar(fontSize: TextUnit, weight: FontWeight, content: @Composable RowScope.() -> Unit) {
    androidx.compose.runtime.CompositionLocalProvider(LocalBarStyle provides BarStyle(fontSize, weight)) {
        Row(
            Modifier
                .fillMaxWidth()
                .height(40.dp)
                .background(Color.Black.copy(alpha = 0.5f))
                .clipToBounds(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            content = content,
        )
    }
}

/** ParameterWidget.swift */
@Composable
private fun RowScope.ParameterItem(model: CameraModel, title: String, index: Int) {
    val active = model.activeIndex == index
    val style = LocalBarStyle.current
    Box(
        Modifier
            .weight(1f)
            .fillMaxHeight()
            .background(if (active) Color.White.copy(alpha = if (model.isAdjustingValue) 0.7f else 0.5f) else Color.Transparent)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                model.selectWidget(index)
            },
        contentAlignment = Alignment.Center,
    ) {
        AutoShrinkText(title, if (active) Color.Black else Color.White, style.fontSize, style.weight)
    }
}

/** Text with lineLimit(1) + minimumScaleFactor(0.65). */
@Composable
fun AutoShrinkText(text: String, color: Color, fontSize: TextUnit, weight: FontWeight, modifier: Modifier = Modifier) {
    var scale by remember(text, fontSize) { mutableFloatStateOf(1f) }
    var ready by remember(text, fontSize) { mutableStateOf(false) }
    Text(
        text = text,
        color = color,
        fontSize = fontSize * scale,
        fontWeight = weight,
        fontFamily = FontFamily.Monospace,
        maxLines = 1,
        softWrap = false,
        textAlign = TextAlign.Center,
        modifier = modifier
            .padding(horizontal = 2.dp)
            .drawWithContent { if (ready) drawContent() },
        onTextLayout = { r ->
            if (r.didOverflowWidth && scale > 0.65f) scale = (scale - 0.05f).coerceAtLeast(0.65f) else ready = true
        },
    )
}
