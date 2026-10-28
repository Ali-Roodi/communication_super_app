package ir.hamrasan.panel

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ir.hamrasan.keybank.Activation

/** What an activation screen keeps while the panel is open: the field and this session's codes. One per [Activation.Target]. */
class ActivationState {
    var input by mutableStateOf("")
    val history = mutableStateListOf<Pair<String, String>>()
}

@Composable
fun ActivationScreen(state: ActivationState, target: Activation.Target) {
    val device = Activation.normalizeDeviceCode(state.input)
    val code = device?.let { Activation.activationCodeFor(it, target) }
    val organization = target == Activation.Target.ORGANIZATION
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(device) {
        // Remember a code once it has been shown, newest first, without repeats.
        if (device != null && code != null) {
            state.history.removeAll { it.first == device }
            state.history.add(0, device to code)
        }
    }

    Column(
        Modifier.verticalScroll(rememberScrollState()).widthIn(max = 760.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Section(if (organization) "کد فعال‌سازی نسخهٔ سازمانی" else "کد فعال‌سازی نسخهٔ بین‌سازمانی", Modifier.fillMaxWidth()) {
            Text(
                if (organization) {
                    "نسخهٔ سازمانی تا فعال نشود باز نمی‌شود و همان صفحهٔ اول، کد دستگاه را نشان می‌دهد. آن کد ۶ نویسه‌ای را این‌جا وارد کنید " +
                        "و کد فعال‌سازی را به کاربر بدهید تا در همان صفحه وارد کند."
                } else {
                    "کاربر کد دستگاهش را در گوشی می‌بیند: تنظیمات ← درباره برنامه ← نسخه بین‌سازمانی. آن کد ۶ نویسه‌ای را این‌جا وارد کنید " +
                        "و کد فعال‌سازی را به او بدهید تا در همان صفحه وارد کند."
                },
                style = MaterialTheme.typography.bodyMedium,
            )
            OutlinedTextField(
                value = state.input,
                onValueChange = { if (it.length <= 24) state.input = it },
                label = { Text("کد دستگاه") },
                placeholder = { Text("4f339b", style = LtrMono.copy(fontSize = 20.sp), color = Color(0xFFB0B7C3)) },
                singleLine = true,
                textStyle = LtrMono.copy(fontSize = 20.sp),
                isError = state.input.isNotBlank() && device == null && state.input.count { !it.isWhitespace() && it != '-' } >= 6,
                supportingText = {
                    when {
                        state.input.isBlank() -> Text("بزرگی و کوچکی حروف، فاصله، خط تیره و رقم فارسی مهم نیست.")
                        device == null -> Text("کد دستگاه ۶ نویسه است، فقط رقم‌ها و حرف‌های a تا f.")
                        else -> Text("کد دستگاه: $device")
                    }
                },
                keyboardActions = KeyboardActions.Default,
                modifier = Modifier.width(360.dp).focusRequester(focus),
            )
            if (code != null) {
                CopyRow("کد فعال‌سازی", Activation.display(code), copyValue = code, big = true)
                Hint("خط تیرهٔ وسط فقط برای راحت خواندن است؛ گوشی با یا بدون آن قبول می‌کند.")
            }
        }

        if (state.history.size > 1 || (state.history.size == 1 && state.history[0].first != device)) {
            Section("کدهای همین نوبت", Modifier.fillMaxWidth()) {
                state.history.forEach { (d, c) ->
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Text(d, style = LtrMono, fontSize = 15.sp, modifier = Modifier.width(90.dp))
                        Text("←", fontSize = 15.sp)
                        Text(Activation.display(c), style = LtrMono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
                Hint("این فهرست با بستن برنامه پاک می‌شود.", size = 12.sp)
            }
        }

        Note(
            if (organization) {
                "این کد فقط نسخهٔ سازمانی را باز می‌کند؛ کد نسخهٔ بین‌سازمانی همان گوشی با آن فرق دارد و در نسخهٔ سازمانی پذیرفته نمی‌شود. " +
                    "کد فعال‌سازی رمز نیست: پیام رمز بدون فایل کلیدی که مرجع امضا کرده ممکن نیست؛ آن در بخش «فایل کلید اعضا» ساخته می‌شود."
            } else {
                "کد فعال‌سازی فقط منوی نسخهٔ بین‌سازمانی را باز می‌کند و رمز نیست. پیام رمز بدون فایل کلیدی که مرجع " +
                    "امضا کرده ممکن نیست؛ آن در بخش «فایل کلید اعضا» ساخته می‌شود. نسخهٔ سازمانی کد خودش را دارد."
            },
        )
    }
}
