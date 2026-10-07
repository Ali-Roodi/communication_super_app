package ir.hamrasan.panel

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.PersonAdd
import androidx.compose.material.icons.outlined.Print
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ir.hamrasan.keybank.Activation
import ir.hamrasan.keybank.AuthorityFolder
import kotlinx.coroutines.delay


@Composable
fun KeysScreen(state: KeysState) {
    val unlocked = state.unlocked
    if (unlocked == null) {
        LockedScreen(state)
    } else {
        LaunchedEffect(unlocked, state.lastActivity) {
            delay(state.idleLockMs)
            state.lock()
        }
        UnlockedScreen(state, unlocked)
    }
    state.delivery?.let { DeliveryDialog(state, it) }
    MemberDialogs(state)
}

@Composable
private fun LockedScreen(state: KeysState) {
    Column(Modifier.widthIn(max = 620.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Section("باز کردن فایل مرجع", Modifier.fillMaxWidth()) {
            Text(
                "برای ساختن فایل کلید، فایل مرجع سازمان (authority.hka) و رمزش لازم است. فهرست اعضا و فایل‌های " +
                    "ساخته‌شده کنار همین فایل نگه داشته می‌شوند (roster.csv و پوشهٔ issued).",
                style = MaterialTheme.typography.bodyMedium,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = {
                    Platform.chooseAuthorityFile(state.authorityFile)?.let {
                        state.authorityFile = it
                        state.error = null
                    }
                }) {
                    Icon(Icons.Outlined.FolderOpen, null, Modifier.size(18.dp))
                    Text("  انتخاب فایل…")
                }
                Text(
                    state.authorityFile?.absolutePath ?: "فایلی انتخاب نشده",
                    style = LtrText,
                    fontSize = 13.sp,
                    color = if (state.authorityFile == null) Color(0xFF8A93A3) else Color(0xFF2B3340),
                )
            }
            OutlinedTextField(
                value = state.password,
                onValueChange = {
                    state.password = it
                    state.error = null
                },
                label = { Text("رمز مرجع") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                textStyle = LtrText,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { state.launch { state.unlock() } }),
                isError = state.error != null,
                supportingText = { state.error?.let { Text(it) } },
                enabled = state.busy == null,
                modifier = Modifier.width(360.dp),
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Button(onClick = { state.launch { state.unlock() } }, enabled = state.busy == null) {
                    Text("باز کردن")
                }
                state.busy?.let { Hint(it) }
            }
        }
        Note(
            "رمز مرجع هیچ‌جا ذخیره نمی‌شود. این بخش با دکمهٔ «قفل»، با بستن برنامه، یا بعد از ۱۰ دقیقه کار نکردن " +
                "دوباره قفل می‌شود. فایل مرجع را روی رایانه‌ای بدون اینترنت نگه دارید و از آن پشتیبان جدا بگیرید.",
        )
    }
}

@Composable
private fun UnlockedScreen(state: KeysState, u: KeysState.Unlocked) {
    val snapshot = state.snapshot
    val members = snapshot?.entries.orEmpty()
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(Modifier.weight(1f)) {
                Text(
                    snapshot?.organization ?: "سازمان هنوز عضوی ندارد",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                )
                // Persian label and Latin value as separate texts: one mixed
                // string is reordered by the bidi algorithm into nonsense.
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Hint("شناسهٔ مرجع", size = 12.sp)
                    Text(u.authorityId, style = LtrMono, fontSize = 12.sp, color = Color(0xFF5A6474))
                }
                Text(u.folder.dir.absolutePath, style = LtrText, fontSize = 12.sp, color = Color(0xFF5A6474))
            }
            OutlinedButton(onClick = { Platform.open(u.folder.dir) }) {
                Icon(Icons.Outlined.FolderOpen, null, Modifier.size(18.dp))
                Text("  پوشهٔ مرجع")
            }
            Button(onClick = { state.lock() }) {
                Icon(Icons.Outlined.Lock, null, Modifier.size(18.dp))
                Text("  قفل")
            }
        }
        snapshot?.let { OutdatedBanner(state, it, u.folder) }
        Row(horizontalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.fillMaxHeight()) {
            NewMemberForm(state, needsOrganization = snapshot?.organization == null, memberCount = members.size, modifier = Modifier.weight(1.1f))
            MembersCard(state, snapshot, Modifier.weight(1f).fillMaxHeight())
        }
    }
}

@Composable
private fun NewMemberForm(state: KeysState, needsOrganization: Boolean, memberCount: Int, modifier: Modifier) {
    val form = remember { MemberForm() }
    var confirm by remember { mutableStateOf(false) }
    val busy = state.busy != null
    val device = Activation.normalizeDeviceCode(form.deviceCode)
    val scroll = rememberScrollState()
    // After an issue the form is empty again: show it from the top.
    LaunchedEffect(state.delivery) { if (state.delivery?.othersReissued != null) scroll.scrollTo(0) }
    // Any edit clears a message about the previous attempt.
    fun edit(set: () -> Unit) { set(); form.error = null }

    Section("عضو جدید", modifier.verticalScroll(scroll)) {
        if (needsOrganization) {
            OutlinedTextField(
                form.organization, { v -> edit { form.organization = v } },
                label = { Text("نام سازمان") },
                supportingText = { Text("در برنامه بالای فهرست اعضا نشان داده می‌شود.") },
                singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth(),
            )
        }
        OutlinedTextField(
            form.name, { v -> edit { form.name = v } },
            label = { Text("نام و نام خانوادگی") },
            singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            form.mobile, { v -> edit { form.mobile = v } },
            label = { Text("شمارهٔ همراه") },
            placeholder = { Text("09121234567", style = LtrText) },
            supportingText = { Text("کلید عضو از همین شماره ساخته می‌شود و پیام رمز به آن فرستاده می‌شود.") },
            textStyle = LtrText, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            form.others, { v -> edit { form.others = v } },
            label = { Text("شماره‌های دیگر (اختیاری)") },
            supportingText = { Text("چند شماره را با ؛ یا ویرگول جدا کنید. پیام رمزی که از این شماره‌ها برسد هم از او شناخته می‌شود.") },
            textStyle = LtrText, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            form.deviceCode, { v -> edit { form.deviceCode = v } },
            label = { Text("کد دستگاه (اختیاری)") },
            supportingText = {
                Text(
                    if (device != null) "کد فعال‌سازی: ${Activation.display(Activation.activationCodeFor(device))}"
                    else "اگر بدهید، کد فعال‌سازی هم روی برگهٔ تحویل می‌آید.",
                )
            },
            textStyle = LtrMono, singleLine = true, enabled = !busy, modifier = Modifier.width(260.dp),
        )
        form.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Button(
                onClick = {
                    if (state.check(form)) {
                        if (memberCount == 0) state.launch { state.addMember(form) } else confirm = true
                    }
                },
                enabled = !busy && form.name.isNotBlank() && form.mobile.isNotBlank(),
            ) {
                Icon(Icons.Outlined.PersonAdd, null, Modifier.size(18.dp))
                Text("  افزودن و ساخت فایل کلید")
            }
            state.busy?.let { Hint(it) }
        }
        state.progress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
    }

    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("افزودن «${form.name.trim()}»") },
            text = {
                Text(
                    "عضو جدید به فهرست اضافه می‌شود و فایل کلید هر ${fa(memberCount + 1)} عضو دوباره ساخته می‌شود. " +
                        "کلید و رمز ${fa(memberCount)} عضو قبلی عوض نمی‌شود، ولی تا فایل تازه‌شان (یا فایل به‌روزرسانی update.hku) را وارد نکنند عضو جدید را نمی‌شناسند. " +
                        "از فهرست فعلی پشتیبان گرفته می‌شود (پوشهٔ backups).",
                )
            },
            confirmButton = {
                Button(onClick = {
                    confirm = false
                    state.launch { state.addMember(form) }
                }) { Text("افزودن") }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("انصراف") } },
            containerColor = Color.White,
        )
    }
}

@Composable
private fun DeliveryDialog(state: KeysState, d: KeysState.Delivery) {
    val justIssued = d.othersReissued != null
    val status = state.statusOf(d.index)
    val amber = Color(0xFFB26A00)
    AlertDialog(
        onDismissRequest = { state.delivery = null },
        icon = if (justIssued) ({ Icon(Icons.Outlined.CheckCircle, null, tint = Color(0xFF1E7D32)) }) else null,
        title = {
            Text(
                when (d.event) {
                    KeysState.Event.ADDED -> "فایل کلید «${d.name}» ساخته شد"
                    KeysState.Event.EDITED -> "«${d.name}» ویرایش شد"
                    KeysState.Event.NEW_KEY -> "کلید و رمز تازهٔ «${d.name}» ساخته شد"
                    null -> d.name
                },
            )
        },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier.widthIn(min = 460.dp).verticalScroll(rememberScrollState()),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(d.phones.joinToString("  ·  "), style = LtrText, color = Color(0xFF5A6474))
                    if (status != null && !justIssued) StatusChip(status)
                }
                if (status != null && !justIssued && status != AuthorityFolder.DeliveryStatus.CURRENT) {
                    Hint(status.explanation(), size = 12.sp)
                }
                CopyRow("فایل کلید", d.file.name, copyValue = d.file.absolutePath)
                if (!d.file.isFile) {
                    Text("این فایل هنوز ساخته نشده است.", color = MaterialTheme.colorScheme.error)
                }
                d.password?.let { CopyRow(if (d.event == KeysState.Event.NEW_KEY) "رمز تازهٔ فایل" else "رمز فایل", it, big = true) }
                d.activationCode?.let { CopyRow("کد فعال‌سازی", Activation.display(it), copyValue = it) }
                Note("فایل و رمز را از دو راه جدا به عضو بدهید؛ مثلاً فایل روی فلش یا پیام‌رسان، رمز روی برگهٔ چاپی یا حضوری.")
                when {
                    d.event == KeysState.Event.NEW_KEY -> Note(
                        "رمز این عضو عوض شد و فایل و رمز قبلی‌اش دیگر باز نمی‌شود. فایل و رمز تازه را روی گوشی تازه‌اش وارد کند.",
                        color = amber,
                    )
                    d.event == KeysState.Event.EDITED && d.keyChanged -> Note(
                        "شمارهٔ همراه این عضو عوض شد، پس کلیدش هم عوض شد. رمزش همان قبلی است؛ فایل تازه را وارد کند.",
                        color = amber,
                    )
                }
                if (justIssued && d.othersReissued!! > 0) {
                    Note(
                        when (d.event) {
                            KeysState.Event.NEW_KEY ->
                                "فایل ${fa(d.othersReissued)} عضو دیگر هم تازه شد. کلید و رمزشان همان قبلی است. تا فایل تازه را وارد نکنند، " +
                                    "هنوز کلید قدیمی «${d.name}» را قبول می‌کنند؛ زود به همه برسانید."
                            KeysState.Event.EDITED ->
                                "فایل ${fa(d.othersReissued)} عضو دیگر هم تازه شد. کلید و رمزشان همان قبلی است؛ تا فایل تازه را وارد نکنند، " +
                                    "این تغییر را نمی‌بینند."
                            else ->
                                "فایل ${fa(d.othersReissued)} عضو دیگر هم تازه شد. کلید و رمزشان همان قبلی است؛ برای اینکه این عضو " +
                                    "جدید را بشناسند، فایل تازهٔ خودشان یا فایل update.hku را از پوشهٔ issued وارد کنند."
                        },
                        color = amber,
                    )
                }
                HorizontalDivider(color = Color(0xFFEEF1F5))
                MemberActions(state, d.index)
            }
        },
        confirmButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (status == AuthorityFolder.DeliveryStatus.STALE) {
                    TextButton(onClick = { state.launch { state.markUpdated(d.index) } }) {
                        Text("به‌روزرسانی را وارد کرد")
                    }
                }
                if (status != null && status != AuthorityFolder.DeliveryStatus.CURRENT) {
                    OutlinedButton(onClick = { state.launch { state.markDelivered(d.index) } }) {
                        Icon(Icons.Outlined.CheckCircle, null, Modifier.size(18.dp))
                        Text("  تحویل داده شد")
                    }
                }
                Button(onClick = { state.delivery = null }) { Text("بستن") }
            }
        },
        dismissButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { Platform.reveal(d.file) }) {
                    Icon(Icons.Outlined.FolderOpen, null, Modifier.size(18.dp))
                    Text("  نشان دادن فایل")
                }
                OutlinedButton(onClick = { state.deliverySheet(d)?.let(Platform::open) }, enabled = d.password != null) {
                    Icon(Icons.Outlined.Print, null, Modifier.size(18.dp))
                    Text("  برگهٔ تحویل")
                }
            }
        },
        shape = RoundedCornerShape(16.dp),
        containerColor = Color.White,
    )
}
