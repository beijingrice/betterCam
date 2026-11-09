package com.ppschool.bettercam.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ppschool.bettercam.R

/**
 * Alerts are drawn inside the rotated workspace (instead of a separate dialog window)
 * so they stay aligned with the landscape camera UI.
 */
@Composable
fun InlineAlert(
    title: String,
    message: String? = null,
    onDismiss: () -> Unit,
    field: (@Composable () -> Unit)? = null,
    confirmLabel: String = stringResource(R.string.ok),
    dismissLabel: String? = null,
    onConfirm: () -> Unit = onDismiss,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.45f))
            .clickable(remember { MutableInteractionSource() }, null) { },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = 300.dp)
                .background(Color(0xFF2C2C2E), RoundedCornerShape(14.dp))
                .padding(top = 18.dp, start = 16.dp, end = 16.dp, bottom = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, textAlign = TextAlign.Center)
            message?.let { Text(it, color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp, textAlign = TextAlign.Center) }
            field?.invoke()
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                dismissLabel?.let { TextButton(onClick = onDismiss) { Text(it, color = Color(0xFF0A84FF)) } }
                TextButton(onClick = onConfirm) { Text(confirmLabel, color = Color(0xFF0A84FF), fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

@Composable
fun DarkTextField(value: String, onValueChange: (String) -> Unit, placeholder: String) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        placeholder = { Text(placeholder) },
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = Color.White, unfocusedTextColor = Color.White,
            focusedBorderColor = Color(0xFF0A84FF), unfocusedBorderColor = Color.Gray,
            cursorColor = Color.White,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}
