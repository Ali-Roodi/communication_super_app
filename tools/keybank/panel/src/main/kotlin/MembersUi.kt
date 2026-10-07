package ir.hamrasan.panel

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.communication_super_app.smscrypto.keybank.Canon
import ir.hamrasan.keybank.AuthorityFolder
import ir.hamrasan.keybank.AuthorityFolder.DeliveryStatus
import ir.hamrasan.keybank.IssuanceLog

private val Green = Color(0xFF1E7D32)
private val Amber = Color(0xFFB26A00)
private val Red = Color(0xFFB3261E)
private val Grey = Color(0xFF5A6474)

/** The label and colour a member's [DeliveryStatus] is shown with. */
fun DeliveryStatus.label() = when (this) {
    DeliveryStatus.CURRENT -> "به‌روز"
    DeliveryStatus.STALE -> "فایل قدیمی"
    DeliveryStatus.NEW_KEY -> "کلید تازه تحویل نشده"
    DeliveryStatus.NOT_RECORDED -> "تحویل ثبت نشده"
}

private fun DeliveryStatus.color() = when (this) {
    DeliveryStatus.CURRENT -> Green
    DeliveryStatus.STALE -> Amber
    DeliveryStatus.NEW_KEY -> Red
    DeliveryStatus.NOT_RECORDED -> Grey
}

/** One sentence on what a status means for the operator. */
fun DeliveryStatus.explanation() = when (this) {
    DeliveryStatus.CURRENT -> "فایل فعلی را تحویل گرفته است."
    DeliveryStatus.STALE -> "فایلی که دارد قدیمی است و تغییرهای بعد از آن را نمی‌شناسد. فایل تازه‌اش را بدهید؛ رمزش عوض نشده."
    DeliveryStatus.NEW_KEY -> "کلید و رمز تازه گرفته که هنوز تحویل نشده است. فایل و رمز تازه را بدهید."
    DeliveryStatus.NOT_RECORDED -> "تحویل فایل به او هنوز ثبت نشده است."
}

@Composable
fun StatusChip(status: DeliveryStatus) {
    val color = status.color()
    Text(
        status.label(),
        fontSize = 12.sp,
        color = color,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.background(color.copy(alpha = 0.10f), RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 2.dp),
    )
}

/**
 * Above the members: who does not hold the current file. A key file carries
 * the whole directory, so every change to the roster leaves everyone else
 * with an old one until they import the new file.
 */
@Composable
fun OutdatedBanner(state: KeysState, snapshot: AuthorityFolder.Snapshot, folder: AuthorityFolder) {
    val outdated = snapshot.outdated
    if (outdated.isEmpty()) return
    val counts = outdated.groupingBy { snapshot.statusOf(it) }.eachCount()
    val parts = listOfNotNull(
        counts[DeliveryStatus.STALE]?.let { "${fa(it)} عضو فایل قدیمی دارند" },
        counts[DeliveryStatus.NEW_KEY]?.let { "${fa(it)} عضو کلید تازه‌شان را نگرفته‌اند" },
        counts[DeliveryStatus.NOT_RECORDED]?.let { "تحویل به ${fa(it)} عضو ثبت نشده" },
    )
    val names = outdated.take(8).joinToString("، ") { it.name } + if (outdated.size > 8) " و ${fa(outdated.size - 8)} نفر دیگر" else ""
    val stale = counts[DeliveryStatus.STALE] ?: 0
    Column(
        Modifier.fillMaxWidth().background(Amber.copy(alpha = 0.08f), RoundedCornerShape(12.dp)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Outlined.WarningAmber, null, tint = Amber)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(parts.joinToString(" · "), fontWeight = FontWeight.Bold, color = Color(0xFF2B3340))
                Text(names, fontSize = 13.sp, color = Color(0xFF2B3340))
                Hint(
                    if (stale > 0 && folder.updateFile.isFile) {
                        "کسی که فایل قدیمی دارد، به‌جای فایل خودش می‌تواند فایل update.hku را وارد کند: برای همه یکی است، " +
                            "رمز نمی‌خواهد و فقط گوشی اعضای همین سازمان بازش می‌کند. کلید تازه فقط در فایل خود عضو است."
                    } else {
                        "فایل تازهٔ هر عضو در پوشهٔ issued است. پس از تحویل، روی عضو کلیک کنید و «تحویل داده شد» را بزنید."
                    },
                    size = 12.sp,
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { Platform.open(folder.issuedDir) }) {
                Icon(Icons.Outlined.FolderOpen, null, Modifier.size(18.dp))
                Text("  پوشهٔ فایل‌ها")
            }
            if (stale > 0 && folder.updateFile.isFile) {
                OutlinedButton(onClick = { Platform.reveal(folder.updateFile) }) {
                    Icon(Icons.Outlined.FolderOpen, null, Modifier.size(18.dp))
                    Text("  فایل به‌روزرسانی")
                }
                TextButton(onClick = { state.dialog = KeysState.Dialog.MarkAll(update = true) }) {
                    Text("همه به‌روزرسانی را وارد کردند…")
                }
            }
            TextButton(onClick = { state.dialog = KeysState.Dialog.MarkAll(update = false) }) { Text("همه فایل خودشان را گرفتند…") }
        }
    }
}

/** The right-hand card: the members, or «دفتر صدور». */
@Composable
fun MembersCard(state: KeysState, snapshot: AuthorityFolder.Snapshot?, modifier: Modifier) {
    val members = snapshot?.entries.orEmpty()
    Section("", modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(
                selected = state.view == KeysState.View.MEMBERS,
                onClick = { state.view = KeysState.View.MEMBERS; state.touch() },
                label = { Text("اعضا (${fa(members.size)})") },
            )
            FilterChip(
                selected = state.view == KeysState.View.LOG,
                onClick = { state.view = KeysState.View.LOG; state.touch() },
                label = { Text("دفتر صدور") },
            )
        }
        when (state.view) {
            KeysState.View.MEMBERS -> MemberList(state, snapshot)
            KeysState.View.LOG -> LogList(snapshot?.log.orEmpty())
        }
    }
}

@Composable
private fun MemberList(state: KeysState, snapshot: AuthorityFolder.Snapshot?) {
    val members = snapshot?.entries.orEmpty()
    if (snapshot == null || members.isEmpty()) {
        Hint("هنوز عضوی ثبت نشده است.")
        return
    }
    Hint("برای دیدن رمز و فایل، ثبت تحویل، ویرایش یا حذف، روی عضو کلیک کنید.", size = 12.sp)
    LazyColumn {
        itemsIndexed(members) { i, entry ->
            Row(
                Modifier.fillMaxWidth().clickable { state.showMember(i) }.padding(vertical = 10.dp, horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    fa(i + 1),
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.background(MaterialTheme.colorScheme.primaryContainer, CircleShape)
                        .padding(horizontal = 9.dp, vertical = 2.dp),
                )
                Column(Modifier.weight(1f)) {
                    Text(entry.name, fontWeight = FontWeight.Medium)
                    Text(entry.phones.joinToString("  ·  "), style = LtrText, fontSize = 13.sp, color = Grey)
                }
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    StatusChip(snapshot.statusOf(entry))
                    if (entry.generation > 0) Hint("نسل ${fa(entry.generation)}", size = 11.sp)
                }
            }
            HorizontalDivider(color = Color(0xFFEEF1F5))
        }
    }
}

/** What a log line says, in Persian. */
fun IssuanceLog.Entry.describe(): String = when (action) {
    IssuanceLog.Action.ADD -> "افزودن «$member»"
    IssuanceLog.Action.EDIT -> "ویرایش «$member»" + if (note.isNotEmpty()) " — کلید تازه" else ""
    IssuanceLog.Action.NEW_KEY -> "کلید و رمز تازه برای «$member» (گوشی گم شد)"
    IssuanceLog.Action.REMOVE -> "حذف «$member» از سازمان"
    IssuanceLog.Action.DELIVERED -> "تحویل فایل به «$member»"
    IssuanceLog.Action.UPDATE_DELIVERED -> "به‌روزرسانی «$member» با فایل به‌روزرسانی"
}

@Composable
private fun LogList(log: List<IssuanceLog.Entry>) {
    if (log.isEmpty()) {
        Hint("هنوز چیزی ثبت نشده است. از این پس هر صدور و هر تحویل اینجا می‌آید (فایل issuance-log.csv در پوشهٔ مرجع).")
        return
    }
    Hint("تازه‌ترین بالا. همین فهرست در فایل issuance-log.csv پوشهٔ مرجع هم هست.", size = 12.sp)
    LazyColumn {
        items(log.asReversed()) { e ->
            Row(
                Modifier.fillMaxWidth().padding(vertical = 8.dp, horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        e.describe(),
                        fontWeight = if (e.action.isIssue) FontWeight.Medium else FontWeight.Normal,
                        color = if (e.action.isIssue) Color(0xFF2B3340) else Grey,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(e.phone, style = LtrText, fontSize = 12.sp, color = Grey)
                        if (e.action.isIssue) Hint("${fa(e.members)} عضو", size = 12.sp)
                    }
                }
                Text(fa(jalaliNow(e.time)), style = LtrText, fontSize = 12.sp, color = Grey)
            }
            HorizontalDivider(color = Color(0xFFEEF1F5))
        }
    }
}

/** The member actions under a member's details: edit, lost phone, remove. */
@Composable
fun MemberActions(state: KeysState, index: Int) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Hint("مدیریت عضو:", size = 12.sp)
        TextButton(onClick = {
            state.editForm(index)?.let { state.dialog = KeysState.Dialog.Edit(index, it) }
        }) { Text("ویرایش") }
        TextButton(onClick = { state.dialog = KeysState.Dialog.NewKey(index) }) { Text("گوشی گم شد") }
        TextButton(onClick = { state.dialog = KeysState.Dialog.Remove(index) }) {
            Text("حذف از سازمان", color = Red)
        }
    }
}

/** Whichever of the member dialogs is open, plus the progress and result dialogs. */
@Composable
fun MemberDialogs(state: KeysState) {
    val members = state.snapshot?.entries.orEmpty()
    when (val d = state.dialog) {
        is KeysState.Dialog.Edit -> EditDialog(state, d)
        is KeysState.Dialog.NewKey -> {
            val name = members.getOrNull(d.index)?.name.orEmpty()
            Confirm(
                state,
                title = "گوشی «$name» گم شده؟",
                text = "برای «$name» کلید و رمز تازه ساخته می‌شود و فایل همهٔ ${fa(members.size)} عضو دوباره ساخته می‌شود. " +
                    "کلید و رمز بقیه عوض نمی‌شود.\n\n" +
                    "فایل و رمز تازه را به «$name» بدهید تا روی گوشی تازه‌اش وارد کند. بقیه هم باید فایل تازه‌شان را وارد کنند؛ " +
                    "از آن به بعد گوشی گم‌شده پیام رمز تازه‌ای نمی‌تواند بخواند و گوشی‌های دیگر پیامی از آن نمی‌پذیرند.",
                action = "ساخت کلید و رمز تازه",
                danger = true,
                check = { state.checkNewKey(d.index) },
            ) { state.newKey(d.index) }
        }
        is KeysState.Dialog.Remove -> {
            val name = members.getOrNull(d.index)?.name.orEmpty()
            Confirm(
                state,
                title = "حذف «$name» از سازمان",
                text = "«$name» از فهرست اعضا برداشته می‌شود، فایل و رمزش از پوشهٔ issued پاک می‌شود و فایل ${fa(members.size - 1)} عضو دیگر " +
                    "دوباره ساخته می‌شود (کلید و رمزشان عوض نمی‌شود).\n\n" +
                    "تا وقتی بقیه فایل تازه را وارد نکرده‌اند، گوشی‌شان هنوز «$name» را می‌شناسد. از فهرست فعلی پشتیبان گرفته می‌شود.",
                action = "حذف",
                danger = true,
                check = { state.checkRemove(d.index) },
            ) { state.removeMember(d.index) }
        }
        is KeysState.Dialog.MarkAll -> if (d.update) {
            Confirm(
                state,
                title = "همه فایل به‌روزرسانی را وارد کرده‌اند؟",
                text = "برای هر ${fa(members.size)} عضو در دفتر صدور ثبت می‌شود که فایل update.hku فعلی را وارد کرده‌اند. فایلی ساخته نمی‌شود. " +
                    "کسی که کلید تازه گرفته یا هنوز فایل خودش را نگرفته، همچنان در فهرست می‌ماند: کلیدش فقط در فایل خود اوست.",
                action = "بله، ثبت کن",
                check = { null },
            ) { state.markAllUpdated() }
        } else {
            Confirm(
                state,
                title = "همهٔ اعضا فایل فعلی را وارد کرده‌اند؟",
                text = "برای هر ${fa(members.size)} عضو در دفتر صدور ثبت می‌شود که فایل فعلی خودشان را تحویل گرفته‌اند. فایلی ساخته نمی‌شود. " +
                    "فقط وقتی بزنید که مطمئنید همه فایل تازه را وارد کرده‌اند.",
                action = "بله، ثبت کن",
                check = { null },
            ) { state.markAllDelivered() }
        }
        null -> {}
    }

    if (state.modalBusy) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text(state.busy ?: "در حال انجام…") },
            text = {
                Column(Modifier.widthIn(min = 360.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    LinearProgressIndicator(progress = { state.progress ?: 0f }, modifier = Modifier.fillMaxWidth())
                    Hint("برنامه را نبندید.")
                }
            },
            confirmButton = {},
            containerColor = Color.White,
        )
    }

    state.notice?.let { n ->
        AlertDialog(
            onDismissRequest = { state.notice = null },
            title = { Text(n.title, color = if (n.isError) Red else Color.Unspecified) },
            text = { Text(n.text, modifier = Modifier.widthIn(min = 360.dp, max = 560.dp)) },
            confirmButton = { Button(onClick = { state.notice = null }) { Text("بستن") } },
            containerColor = Color.White,
        )
    }
}

@Composable
private fun Confirm(
    state: KeysState,
    title: String,
    text: String,
    action: String,
    danger: Boolean = false,
    check: () -> String?,
    run: suspend () -> Unit,
) {
    AlertDialog(
        onDismissRequest = { state.dialog = null },
        title = { Text(title) },
        text = { Text(text, modifier = Modifier.widthIn(min = 360.dp, max = 560.dp)) },
        confirmButton = {
            Button(
                onClick = {
                    state.dialog = null
                    val problem = check()
                    if (problem != null) {
                        state.notice = KeysState.Notice("انجام نشد", problem, isError = true)
                    } else {
                        state.launch { run() }
                    }
                },
                colors = if (danger) ButtonDefaults.buttonColors(containerColor = Red) else ButtonDefaults.buttonColors(),
            ) { Text(action) }
        },
        dismissButton = { TextButton(onClick = { state.dialog = null }) { Text("انصراف") } },
        containerColor = Color.White,
    )
}

@Composable
private fun EditDialog(state: KeysState, d: KeysState.Dialog.Edit) {
    val form = d.form
    val entry = state.snapshot?.entries?.getOrNull(d.index)
    val count = state.snapshot?.entries?.size ?: 0
    fun edit(set: () -> Unit) { set(); form.error = null; state.touch() }
    val mobileChanged = entry != null && Canon.phone(form.mobile.trim()).let { it != null && it != entry.phones.first() }
    AlertDialog(
        onDismissRequest = { state.dialog = null },
        title = { Text("ویرایش «${entry?.name.orEmpty()}»") },
        text = {
            Column(Modifier.widthIn(min = 460.dp, max = 560.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    form.name, { v -> edit { form.name = v } },
                    label = { Text("نام و نام خانوادگی") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    form.mobile, { v -> edit { form.mobile = v } },
                    label = { Text("شمارهٔ همراه") }, textStyle = LtrText, singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    form.others, { v -> edit { form.others = v } },
                    label = { Text("شماره‌های دیگر (اختیاری)") }, textStyle = LtrText, singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
                if (mobileChanged) {
                    Note(
                        "با عوض شدن شمارهٔ همراه، کلید این عضو هم عوض می‌شود و باید فایل تازه‌اش را وارد کند. رمزش همان قبلی می‌ماند.",
                        color = Amber,
                    )
                }
                Hint("فایل همهٔ ${fa(count)} عضو دوباره ساخته می‌شود؛ رمز هیچ‌کس عوض نمی‌شود. از فهرست فعلی پشتیبان گرفته می‌شود.", size = 12.sp)
                form.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    if (state.checkEdit(d.index, form) != null) {
                        state.dialog = null
                        state.launch { state.editMember(d.index, form) }
                    }
                },
                enabled = form.name.isNotBlank() && form.mobile.isNotBlank(),
            ) { Text("ذخیره و ساخت فایل‌ها") }
        },
        dismissButton = { TextButton(onClick = { state.dialog = null }) { Text("انصراف") } },
        containerColor = Color.White,
    )
}
