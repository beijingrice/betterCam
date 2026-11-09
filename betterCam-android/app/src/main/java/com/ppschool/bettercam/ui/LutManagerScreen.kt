package com.ppschool.bettercam.ui

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ppschool.bettercam.CameraModel
import com.ppschool.bettercam.R
import com.ppschool.bettercam.engine.FilmEngine
import com.ppschool.bettercam.engine.FilmSimulation
import com.ppschool.bettercam.engine.FilmStyleType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

private val RowBg = Color(0xFF1C1C1E)
private val Accent = Color(0xFF0A84FF)

/** LUTManagerView.swift */
@Composable
fun LutManagerScreen(model: CameraModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var renaming by remember { mutableStateOf<FilmSimulation?>(null) }
    var newName by remember { mutableStateOf("") }
    var openRow by remember { mutableStateOf<String?>(null) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            val name = displayName(context, uri)
            withContext(Dispatchers.IO) { FilmEngine.importCube(uri, name) }
            model.pm.syncAllLUTsToOptions()
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 16.dp)) {
                Text(
                    stringResource(R.string.luts_management), color = Color.White, fontWeight = FontWeight.SemiBold,
                    fontSize = 17.sp, modifier = Modifier.align(Alignment.Center)
                )
                Text(
                    stringResource(R.string.done), color = Accent, fontWeight = FontWeight.SemiBold, fontSize = 17.sp,
                    modifier = Modifier.align(Alignment.CenterEnd).clickable { model.showCameraView(true) }.padding(8.dp)
                )
            }
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
                item {
                    Text(
                        stringResource(R.string.my_luts).uppercase(), color = Color.Gray, fontSize = 13.sp,
                        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 6.dp)
                    )
                }
                val sims = FilmEngine.availableSimulations
                items(sims, key = { it.id }) { sim ->
                    val first = sim === sims.first()
                    val last = sim === sims.last()
                    val shape = RoundedCornerShape(
                        topStart = if (first) 10.dp else 0.dp, topEnd = if (first) 10.dp else 0.dp,
                        bottomStart = if (last) 10.dp else 0.dp, bottomEnd = if (last) 10.dp else 0.dp,
                    )
                    Box(Modifier.clip(shape)) {
                        SwipeRow(
                            sim = sim,
                            open = openRow == sim.id,
                            onOpenChange = { openRow = if (it) sim.id else null },
                            onRename = { renaming = sim; newName = sim.name; openRow = null },
                            onDelete = {
                                openRow = null
                                FilmEngine.deleteSimulation(sim)
                                model.pm.syncAllLUTsToOptions()
                            },
                        )
                    }
                    if (!last) HorizontalDivider(color = Color.White.copy(alpha = 0.08f), modifier = Modifier.padding(start = 16.dp))
                }
                item {
                    Spacer(Modifier.height(28.dp))
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(RowBg)
                            .clickable { picker.launch(arrayOf("*/*")) }
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.Add, null, tint = Accent, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(10.dp))
                        Text(stringResource(R.string.import_lut), color = Accent, fontSize = 16.sp)
                    }
                    Spacer(Modifier.height(24.dp))
                }
            }
        }

        renaming?.let { sim ->
            InlineAlert(
                title = stringResource(R.string.rename_lut),
                message = stringResource(R.string.rename_message),
                field = { DarkTextField(newName, { newName = it }, stringResource(R.string.enter_new_name)) },
                dismissLabel = stringResource(R.string.cancel),
                onDismiss = { renaming = null; newName = "" },
                onConfirm = {
                    if (newName.isNotBlank()) {
                        FilmEngine.renameSimulation(sim, newName.trim())
                        model.pm.syncAllLUTsToOptions()
                    }
                    renaming = null; newName = ""
                },
            )
        }
    }
}

/** List row with iOS-style trailing swipe actions (only for user-imported LUTs). */
@Composable
private fun SwipeRow(
    sim: FilmSimulation, open: Boolean, onOpenChange: (Boolean) -> Unit,
    onRename: () -> Unit, onDelete: () -> Unit,
) {
    val editable = sim.type == FilmStyleType.LUT
    val actionWidth = 80.dp
    val revealPx = with(LocalDensity.current) { (actionWidth * 2).toPx() }
    val offset = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    androidx.compose.runtime.LaunchedEffect(open) { offset.animateTo(if (open) -revealPx else 0f) }

    Box(Modifier.fillMaxWidth().height(46.dp).background(RowBg)) {
        if (editable) {
            Row(Modifier.align(Alignment.CenterEnd).fillMaxHeight()) {
                SwipeAction(stringResource(R.string.rename), Icons.Filled.Edit, Color(0xFFFF9500), actionWidth, onRename)
                SwipeAction(stringResource(R.string.delete), Icons.Filled.Delete, Color(0xFFFF3B30), actionWidth, onDelete)
            }
        }
        Row(
            Modifier
                .fillMaxSize()
                .offset { IntOffset(offset.value.roundToInt(), 0) }
                .background(RowBg)
                .then(
                    if (!editable) Modifier else Modifier.pointerInput(sim.id) {
                        detectHorizontalDragGestures(
                            onDragEnd = { onOpenChange(offset.value < -revealPx / 2) ; scope.launch { offset.animateTo(if (offset.value < -revealPx / 2) -revealPx else 0f) } },
                        ) { change, drag ->
                            change.consume()
                            scope.launch { offset.snapTo((offset.value + drag).coerceIn(-revealPx, 0f)) }
                        }
                    }
                )
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(sim.name, color = Color.White, fontSize = 16.sp)
        }
    }
}

@Composable
private fun SwipeAction(label: String, icon: ImageVector, color: Color, width: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    Column(
        Modifier.width(width).fillMaxHeight().background(color).clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(icon, null, tint = Color.White, modifier = Modifier.size(16.dp))
        Text(label, color = Color.White, fontSize = 11.sp)
    }
}

private fun displayName(context: android.content.Context, uri: Uri): String {
    var name: String? = null
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) name = c.getString(0)
    }
    return (name ?: "LUT").substringBeforeLast('.')
}
