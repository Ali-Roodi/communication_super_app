package ir.hamrasan.panel

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.Typography
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.platform.Font
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

/** The logo's own ground (`Hamresan-Logo.svg`, `@color/ic_launcher_background`). */
val Navy = Color(0xFF023066)

val Vazirmatn = FontFamily(
    Font("Vazirmatn-Regular.ttf", FontWeight.Normal),
    Font("Vazirmatn-Medium.ttf", FontWeight.Medium),
    Font("Vazirmatn-SemiBold.ttf", FontWeight.SemiBold),
    Font("Vazirmatn-Bold.ttf", FontWeight.Bold),
)

private fun typography(): Typography {
    val base = Typography()
    fun TextStyle.v() = copy(fontFamily = Vazirmatn)
    return Typography(
        displayLarge = base.displayLarge.v(), displayMedium = base.displayMedium.v(), displaySmall = base.displaySmall.v(),
        headlineLarge = base.headlineLarge.v(), headlineMedium = base.headlineMedium.v(), headlineSmall = base.headlineSmall.v(),
        titleLarge = base.titleLarge.v(), titleMedium = base.titleMedium.v(), titleSmall = base.titleSmall.v(),
        bodyLarge = base.bodyLarge.v(), bodyMedium = base.bodyMedium.v(), bodySmall = base.bodySmall.v(),
        labelLarge = base.labelLarge.v(), labelMedium = base.labelMedium.v(), labelSmall = base.labelSmall.v(),
    )
}

private val colors = lightColorScheme(
    primary = Navy,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDCE6F5),
    onPrimaryContainer = Navy,
    secondaryContainer = Color(0xFFDCE6F5),
    onSecondaryContainer = Navy,
    background = Color(0xFFF5F7FA),
    surface = Color.White,
    surfaceVariant = Color(0xFFEEF2F7),
    error = Color(0xFFB3261E),
)

@Composable
fun PanelTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors, typography = typography()) {
        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Rtl) {
            Surface(color = MaterialTheme.colorScheme.background, content = content)
        }
    }
}

enum class Section { Activation, Keys }

fun main(args: Array<String>) {
    if (args.firstOrNull() == "--self-test") {
        val ok = SelfTest.run(java.io.File(args.getOrElse(1) { "." }))
        kotlin.system.exitProcess(if (ok) 0 else 1)
    }
    window()
}

private fun window() = application {
    val keys = remember { KeysState() }
    Window(
        onCloseRequest = {
            keys.lock()
            exitApplication()
        },
        title = "پنل صدور هم‌رسان",
        icon = painterResource("icon.png"),
        state = rememberWindowState(width = 1040.dp, height = 760.dp),
    ) {
        // Below this the two columns of «فایل کلید اعضا» stop being usable.
        LaunchedEffect(Unit) { window.minimumSize = java.awt.Dimension(800, 560) }
        PanelTheme { Panel(keys) }
    }
}

@Composable
fun Panel(
    keys: KeysState,
    start: Section = Section.Activation,
    activation: ActivationState = remember { ActivationState() },
) {
    var section by remember { mutableStateOf(start) }
    Column(Modifier.fillMaxSize()) {
        Header()
        Row(Modifier.fillMaxSize()) {
            NavigationRail(
                modifier = Modifier.fillMaxHeight().width(112.dp),
                containerColor = MaterialTheme.colorScheme.surface,
            ) {
                Spacer(Modifier.padding(top = 8.dp))
                NavigationRailItem(
                    selected = section == Section.Activation,
                    onClick = { section = Section.Activation },
                    icon = { Icon(Icons.Outlined.Key, null) },
                    label = { Text("کد فعال‌سازی", textAlign = androidx.compose.ui.text.style.TextAlign.Center) },
                )
                NavigationRailItem(
                    selected = section == Section.Keys,
                    onClick = { section = Section.Keys },
                    icon = { Icon(if (keys.unlocked == null) Icons.Outlined.Lock else Icons.Outlined.Groups, null) },
                    label = { Text("فایل کلید اعضا", textAlign = androidx.compose.ui.text.style.TextAlign.Center) },
                )
            }
            VerticalDivider()
            Box(Modifier.fillMaxSize().padding(28.dp)) {
                when (section) {
                    Section.Activation -> ActivationScreen(activation)
                    Section.Keys -> KeysScreen(keys)
                }
            }
        }
    }
}

@Composable
private fun Header() {
    Row(
        Modifier.fillMaxWidth().background(Navy).padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Image(painterResource("icon.png"), null, Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)))
        Column {
            Text("پنل صدور هم‌رسان", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold, fontFamily = Vazirmatn)
            Text(
                "کد فعال‌سازی نسخهٔ بین‌سازمانی و فایل کلید اعضا",
                color = Color.White.copy(alpha = 0.75f),
                fontSize = 12.sp,
                fontFamily = Vazirmatn,
            )
        }
    }
}
