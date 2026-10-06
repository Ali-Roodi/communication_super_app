package ir.hamrasan.panel

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

/** Text that is a code, a number or a path: always left to right, monospaced digits. */
val LtrMono = TextStyle(fontFamily = FontFamily.Monospace, textDirection = TextDirection.Ltr)
val LtrText = TextStyle(textDirection = TextDirection.Ltr)

private val persianDigits = "۰۱۲۳۴۵۶۷۸۹"

/** ASCII digits as Persian ones, for numbers inside Persian sentences. */
fun fa(value: Any): String = value.toString().map { if (it in '0'..'9') persianDigits[it - '0'] else it }.joinToString("")

@Composable
fun Section(title: String, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(1.dp, Color(0xFFE1E6EE)),
        shape = RoundedCornerShape(14.dp),
    ) {
        Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            content()
        }
    }
}

@Composable
fun Note(text: String, color: Color = MaterialTheme.colorScheme.primary) {
    Row(
        Modifier.fillMaxWidth().background(color.copy(alpha = 0.07f), RoundedCornerShape(10.dp)).padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Outlined.Info, null, tint = color, modifier = Modifier.size(20.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = Color(0xFF2B3340))
    }
}

/** A labelled value (a code, a password, a path) with a copy button that confirms itself. */
@Composable
fun CopyRow(label: String, value: String, copyValue: String = value, big: Boolean = false) {
    var copied by remember(value) { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1800)
            copied = false
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, style = MaterialTheme.typography.labelLarge, color = Color(0xFF5A6474))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                Text(
                    value,
                    style = LtrMono,
                    fontSize = if (big) 26.sp else 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
                        .padding(horizontal = 14.dp, vertical = if (big) 10.dp else 6.dp),
                )
            }
            OutlinedButton(onClick = {
                Platform.copy(copyValue)
                copied = true
            }) {
                Icon(Icons.Outlined.ContentCopy, null, Modifier.size(18.dp))
                Text(if (copied) "  کپی شد" else "  کپی")
            }
        }
    }
}

@Composable
fun Hint(text: String, color: Color = Color(0xFF5A6474), size: TextUnit = 13.sp) {
    Text(text, color = color, fontSize = size, style = MaterialTheme.typography.bodySmall)
}
