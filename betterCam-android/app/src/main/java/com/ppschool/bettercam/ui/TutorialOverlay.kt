package com.ppschool.bettercam.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ppschool.bettercam.CameraModel
import com.ppschool.bettercam.R

/** TutorialOverlay.swift: two-page first-launch guide drawn on the LCD. */
@Composable
fun TutorialOverlay(model: CameraModel) {
    var showsControls by remember { mutableStateOf(false) }
    BoxWithConstraints(Modifier.fillMaxSize().background(Color(0.06f, 0.06f, 0.06f)).clipToBounds()) {
        val wide = maxWidth >= 520.dp
        Column(Modifier.fillMaxSize()) {
            key(showsControls) {
                Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(if (wide) 24.dp else 14.dp)) {
                    val sections: List<Pair<String, List<String>>> = if (showsControls) listOf(
                        stringResource(R.string.tut_physical) to listOf(stringResource(R.string.tut_rotate), stringResource(R.string.tut_press_center)),
                        stringResource(R.string.tut_capture) to listOf(stringResource(R.string.tut_press_shutter)),
                    ) else listOf(
                        stringResource(R.string.tut_in_camera) to listOf(
                            "↔  " + stringResource(R.string.tut_swipe_h), "↕  " + stringResource(R.string.tut_swipe_v)
                        ),
                        stringResource(R.string.tut_bottom_bar) to listOf(stringResource(R.string.tut_style_manage), stringResource(R.string.tut_swipe_left)),
                    )
                    if (wide) {
                        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                            sections.forEach { (t, lines) -> TutorialSection(t, lines, Modifier.weight(1f)) }
                        }
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            sections.forEach { (t, lines) -> TutorialSection(t, lines, Modifier.fillMaxWidth()) }
                        }
                    }
                }
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.15f))
            Box(Modifier.fillMaxWidth().padding(horizontal = 4.dp), contentAlignment = Alignment.CenterEnd) {
                Box(
                    Modifier
                        .defaultMinSize(minHeight = 44.dp)
                        .clickable {
                            if (showsControls) model.completeTutorial() else showsControls = true
                        }
                        .padding(horizontal = 18.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(if (showsControls) R.string.start_shooting else R.string.got_it),
                        color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp,
                    )
                }
            }
        }
    }
}

@Composable
private fun TutorialSection(title: String, lines: List<String>, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        lines.forEach { Text(it, color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp) }
    }
}
