package ir.hamrasan.panel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.Canon
import ir.hamrasan.keybank.Activation
import ir.hamrasan.keybank.AuthorityFolder
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.swing.SwingUtilities
import kotlin.coroutines.CoroutineContext
import java.io.File
import java.security.SecureRandom

/**
 * The key section's state. The authority is held in memory only while the
 * section is open; [lock] drops it, and so does closing the window or ten
 * idle minutes. Its password is never stored — only the file's path is.
 */
class KeysState(
    private val rememberFile: Boolean = true,
    /** Idle time after which the authority is dropped from memory. */
    val idleLockMs: Long = 10 * 60 * 1000L,
) {
    class Unlocked(val contents: AuthorityFile.Contents, val folder: AuthorityFolder) {
        val authorityId: String = contents.key.public.authorityId.joinToString("") { "%02x".format(it) }
    }

    /** What just happened to the member a [Delivery] is shown for. */
    enum class Event { ADDED, EDITED, NEW_KEY }

    /** What the details dialog shows: one member's file, password and (when known) activation code. */
    class Delivery(
        val index: Int,
        val name: String,
        val phones: List<String>,
        val file: File,
        val password: String?,
        val activationCode: String?,
        /** Set right after an issue: how many other members got a fresh file. */
        val othersReissued: Int? = null,
        val event: Event? = null,
        /** Whether this member's key changed in that issue. */
        val keyChanged: Boolean = false,
    )

    /** A short result or error shown in its own dialog. */
    class Notice(val title: String, val text: String, val isError: Boolean = false)

    enum class View { MEMBERS, LOG }

    /** A confirmation or form opened from a member's dialog. */
    sealed class Dialog {
        class Edit(val index: Int, val form: MemberForm) : Dialog()
        class NewKey(val index: Int) : Dialog()
        class Remove(val index: Int) : Dialog()

        /** Recording for everyone: their own file ([update] false) or the update file. */
        class MarkAll(val update: Boolean) : Dialog()
    }

    private val random = SecureRandom()

    /**
     * Where every change the operator starts runs — never a composable's
     * scope. A dialog's scope dies with the dialog: the confirmation of
     * «گوشی گم شد» closed itself as it started the job, the job was
     * cancelled half-way through, and the panel said «nothing changed» over
     * a new key it had in fact issued, without ever showing its password
     * (found driving the installed panel, 1405/07/15). Switching to the
     * activation tab mid-issue did the same to «عضو جدید». It runs on the
     * AWT event thread, the window's own (see [Edt]).
     */
    private val work = CoroutineScope(SupervisorJob() + Edt)

    /**
     * The AWT event thread as a dispatcher. kotlinx-coroutines-swing is not
     * on the classpath (Compose Desktop does not bring it), and this is all
     * it would add here.
     */
    private object Edt : CoroutineDispatcher() {
        override fun dispatch(context: CoroutineContext, block: Runnable) = SwingUtilities.invokeLater(block)
    }

    /** Runs [block] to the end whatever happens to the screen that started it. */
    fun launch(block: suspend () -> Unit): Job = work.launch { block() }

    var authorityFile by mutableStateOf(if (rememberFile) Platform.lastAuthorityFile?.takeIf { it.isFile } else null)
    var password by mutableStateOf("")
    var error by mutableStateOf<String?>(null)
    var busy by mutableStateOf<String?>(null)
    var progress by mutableStateOf<Float?>(null)
    var unlocked by mutableStateOf<Unlocked?>(null)
        private set
    var snapshot by mutableStateOf<AuthorityFolder.Snapshot?>(null)
        private set
    var delivery by mutableStateOf<Delivery?>(null)
    var notice by mutableStateOf<Notice?>(null)
    var view by mutableStateOf(View.MEMBERS)
    var dialog by mutableStateOf<Dialog?>(null)

    /** True while a change started from a member's dialog is running (a blocking progress dialog). */
    var modalBusy by mutableStateOf(false)
        private set
    var lastActivity by mutableStateOf(System.currentTimeMillis())
        private set

    fun touch() {
        lastActivity = System.currentTimeMillis()
    }

    fun lock() {
        unlocked = null
        snapshot = null
        delivery = null
        notice = null
        dialog = null
        view = View.MEMBERS
        password = ""
        error = null
    }

    suspend fun unlock() {
        val file = authorityFile ?: run { error = "اول فایل مرجع را انتخاب کنید."; return }
        if (password.isEmpty()) {
            error = "رمز مرجع را وارد کنید."
            return
        }
        error = null
        busy = "در حال باز کردن فایل مرجع…"
        try {
            val opened = withContext(Dispatchers.Default) {
                val contents = AuthorityFile.open(file.readBytes(), password)
                val folder = AuthorityFolder(file.absoluteFile.parentFile)
                Unlocked(contents, folder) to folder.snapshot()
            }
            unlocked = opened.first
            snapshot = opened.second
            password = ""
            if (rememberFile) Platform.lastAuthorityFile = file
            touch()
        } catch (e: SmsCryptoException) {
            error = when (e.code) {
                SmsCryptoException.Code.WRONG_PASSWORD -> "رمز مرجع اشتباه است."
                SmsCryptoException.Code.NOT_A_KEY_FILE -> "این فایل، فایل مرجع هم‌رسان نیست."
                else -> "فایل مرجع باز نشد (${e.code})."
            }
        } catch (e: Exception) {
            error = "فایل مرجع باز نشد: ${e.message}"
        } finally {
            busy = null
        }
    }

    /**
     * Checks [form] without writing anything; sets [MemberForm.error] and
     * answers false on a mistake. Run before the confirmation, so the
     * operator never agrees to a re-issue that is then refused.
     */
    fun check(form: MemberForm): Boolean {
        val u = unlocked ?: return false
        touch()
        form.error = null
        if (form.deviceCode.isNotBlank() && Activation.normalizeDeviceCode(form.deviceCode) == null) {
            form.error = "کد دستگاه ۶ نویسه است، فقط رقم‌ها و حرف‌های a تا f. اگر ندارید خالی بگذارید."
            return false
        }
        return try {
            u.folder.prepare(form.name, form.phones(), form.organization)
            true
        } catch (e: AuthorityFolder.MemberError) {
            form.error = e.message
            false
        } catch (e: Exception) {
            form.error = "فهرست اعضا خوانده نشد: ${e.message}"
            false
        }
    }

    suspend fun addMember(form: MemberForm) {
        val u = unlocked ?: return
        if (!check(form)) return
        val deviceCode = form.deviceCode.takeIf { it.isNotBlank() }?.let(Activation::normalizeDeviceCode)
        busy = "در حال ساخت فایل‌ها…"
        progress = 0f
        try {
            val issued = withContext(Dispatchers.Default) {
                u.folder.addMember(
                    u.contents,
                    form.name,
                    form.phones(),
                    random,
                    organization = form.organization,
                ) { done, total -> progress = done.toFloat() / total }
            }
            // Issued: a list that cannot be re-read now is not a failed issue.
            snapshot = runCatching { withContext(Dispatchers.IO) { u.folder.snapshot() } }.getOrNull() ?: snapshot
            val mine = issued.last()
            delivery = Delivery(
                mine.index,
                mine.entry.name,
                mine.entry.phones,
                mine.file,
                mine.password,
                deviceCode?.let(Activation::activationCodeFor),
                othersReissued = issued.size - 1,
                event = Event.ADDED,
                keyChanged = true,
            )
            form.clear()
        } catch (e: AuthorityFolder.MemberError) {
            form.error = e.message
        } catch (e: Exception) {
            form.error = "ساخت فایل‌ها انجام نشد: ${e.message}"
        } finally {
            busy = null
            progress = null
            touch()
        }
    }

    fun showMember(index: Int) {
        val u = unlocked ?: return
        val s = snapshot ?: return
        val entry = s.entries.getOrNull(index) ?: return
        touch()
        delivery = Delivery(index, entry.name, entry.phones, u.folder.keyFileOf(index, entry), s.passwordOf(entry), null)
    }

    /** Where member [index] stands; null when there is no such member. */
    fun statusOf(index: Int): AuthorityFolder.DeliveryStatus? =
        snapshot?.let { s -> s.entries.getOrNull(index)?.let(s::statusOf) }

    // ── Deliveries ───────────────────────────────────────────────────────

    /** Records that member [index] now holds their current file. */
    suspend fun markDelivered(index: Int) = markDelivered(listOf(index))

    /** Records that every member now holds their current file. */
    suspend fun markAllDelivered() = markDelivered(snapshot?.entries?.indices?.toList().orEmpty())

    /** Records that member [index] imported the update file. */
    suspend fun markUpdated(index: Int) = record { it.markUpdated(listOf(index)) }

    /** Records that every member imported the update file. */
    suspend fun markAllUpdated() = record { f -> f.markUpdated(snapshot?.entries?.indices?.toList().orEmpty()) }

    private suspend fun markDelivered(indices: List<Int>) = record { it.markDelivered(indices) }

    private suspend fun record(write: (AuthorityFolder) -> Unit) {
        val u = unlocked ?: return
        touch()
        try {
            snapshot = withContext(Dispatchers.IO) {
                write(u.folder)
                u.folder.snapshot()
            }
        } catch (e: Exception) {
            notice = Notice("ثبت نشد", "تحویل در دفتر صدور ثبت نشد: ${e.message}", isError = true)
        }
    }

    // ── Changing a member ────────────────────────────────────────────────

    /** A form holding member [index] as it is now, for «ویرایش». */
    fun editForm(index: Int): MemberForm? {
        val entry = snapshot?.entries?.getOrNull(index) ?: return null
        return MemberForm().apply {
            name = entry.name
            mobile = entry.phones.first()
            others = entry.phones.drop(1).joinToString("؛ ")
        }
    }

    /**
     * Checks an edit without writing anything; null and [MemberForm.error]
     * on a mistake, else whether the member's key would change.
     */
    fun checkEdit(index: Int, form: MemberForm): Boolean? {
        val u = unlocked ?: return null
        touch()
        form.error = null
        return try {
            u.folder.prepareEdit(index, form.name, form.phones()).keyChanged
        } catch (e: AuthorityFolder.MemberError) {
            form.error = e.message
            null
        } catch (e: Exception) {
            form.error = "فهرست اعضا خوانده نشد: ${e.message}"
            null
        }
    }

    suspend fun editMember(index: Int, form: MemberForm) {
        val keyChanged = checkEdit(index, form) ?: return
        change("در حال ساخت فایل‌ها…") { u, progress ->
            val issued = u.folder.editMember(u.contents, index, form.name, form.phones(), random, progress = progress)
            issued[index].let {
                Delivery(it.index, it.entry.name, it.entry.phones, it.file, it.password, null,
                    othersReissued = issued.size - 1, event = Event.EDITED, keyChanged = keyChanged)
            }
        }
    }

    /** Checks «گوشی گم شد» for member [index]; the error text, or null when it can go ahead. */
    fun checkNewKey(index: Int): String? = check { it.folder.prepareNewKey(index) }

    suspend fun newKey(index: Int) {
        change("در حال ساخت کلید تازه…") { u, progress ->
            val issued = u.folder.newKey(u.contents, index, random, progress = progress)
            issued[index].let {
                Delivery(it.index, it.entry.name, it.entry.phones, it.file, it.password, null,
                    othersReissued = issued.size - 1, event = Event.NEW_KEY, keyChanged = true)
            }
        }
    }

    /** Checks removing member [index]; the error text, or null when it can go ahead. */
    fun checkRemove(index: Int): String? = check { it.folder.prepareRemove(index) }

    suspend fun removeMember(index: Int) {
        val name = snapshot?.entries?.getOrNull(index)?.name ?: return
        change("در حال ساخت فایل‌ها…") { u, progress ->
            val issued = u.folder.removeMember(u.contents, index, random, progress = progress)
            notice = Notice(
                "«$name» حذف شد",
                "فایل و رمز او از پوشهٔ issued برداشته شد. فایل ${fa(issued.size)} عضو دیگر تازه شد و رمزشان همان قبلی است. " +
                    "تا وقتی فایل تازه را وارد نکرده‌اند، گوشی‌شان هنوز «$name» را می‌شناسد و با او پیام رمز رد و بدل می‌کند؛ " +
                    "پس فایل تازه را زود به همه برسانید.",
            )
            null
        }
    }

    private fun check(prepare: (Unlocked) -> Unit): String? {
        val u = unlocked ?: return "بخش کلیدها قفل است."
        touch()
        return try {
            prepare(u)
            null
        } catch (e: AuthorityFolder.MemberError) {
            e.message
        } catch (e: Exception) {
            "فهرست اعضا خوانده نشد: ${e.message}"
        }
    }

    /**
     * Runs a change to the roster behind a blocking progress dialog, then
     * shows the [Delivery] it returns (or nothing — a [Notice] it set).
     */
    private suspend fun change(label: String, block: (Unlocked, (Int, Int) -> Unit) -> Delivery?) {
        val u = unlocked ?: return
        delivery = null
        busy = label
        progress = 0f
        modalBusy = true
        val result = try {
            withContext(Dispatchers.Default) {
                block(u) { done, total -> progress = done.toFloat() / total }
            }
        } catch (e: AuthorityFolder.MemberError) {
            notice = Notice("انجام نشد", e.message.orEmpty(), isError = true)
            return
        } catch (e: Exception) {
            // Issuing is all or nothing (Issuance.issue), so this is true.
            notice = Notice("انجام نشد", "ساخت فایل‌ها انجام نشد و چیزی تغییر نکرد: ${e.message}", isError = true)
            return
        } finally {
            busy = null
            progress = null
            modalBusy = false
            touch()
        }
        // The files are issued: a list that cannot be re-read now must not
        // turn that into an error.
        snapshot = runCatching { withContext(Dispatchers.IO) { u.folder.snapshot() } }.getOrNull() ?: snapshot
        delivery = result
    }

    fun deliverySheet(d: Delivery): File? {
        val u = unlocked ?: return null
        val org = snapshot?.organization ?: return null
        touch()
        return DeliverySheet.write(File(u.folder.dir, "delivery"), org, d)
    }
}

class MemberForm {
    var name by mutableStateOf("")
    var mobile by mutableStateOf("")
    var others by mutableStateOf("")
    var deviceCode by mutableStateOf("")
    var organization by mutableStateOf("")
    var error by mutableStateOf<String?>(null)

    /**
     * The mobile first — the key and the encrypted SMS go by it — then the
     * others. Numbers are separated by ؛ ; ، , or a new line. A space is part
     * of a number (`021 8877 6655` is one landline, the way people write it);
     * only a piece that is not one number as a whole is split at its spaces,
     * so `09121112233 09351112233` still gives two.
     */
    fun phones(): List<String> =
        listOf(mobile) + others.split(';', '؛', ',', '،', '\n', '\t').flatMap { piece ->
            val p = piece.trim()
            when {
                p.isEmpty() -> emptyList()
                Canon.phone(p) != null -> listOf(p)
                else -> p.split(' ').filter { it.isNotBlank() }
            }
        }

    fun clear() {
        name = ""
        mobile = ""
        others = ""
        deviceCode = ""
        error = null
    }
}
