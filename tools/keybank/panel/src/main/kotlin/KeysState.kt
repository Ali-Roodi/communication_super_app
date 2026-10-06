package ir.hamrasan.panel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.Canon
import ir.hamrasan.keybank.Activation
import ir.hamrasan.keybank.AuthorityFolder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
    )

    private val random = SecureRandom()

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
    var lastActivity by mutableStateOf(System.currentTimeMillis())
        private set

    fun touch() {
        lastActivity = System.currentTimeMillis()
    }

    fun lock() {
        unlocked = null
        snapshot = null
        delivery = null
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
            snapshot = withContext(Dispatchers.IO) { u.folder.snapshot() }
            val mine = issued.last()
            delivery = Delivery(
                mine.index,
                mine.entry.name,
                mine.entry.phones,
                mine.file,
                mine.password,
                deviceCode?.let(Activation::activationCodeFor),
                othersReissued = issued.size - 1,
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
        val entry = s.entries[index]
        touch()
        delivery = Delivery(index, entry.name, entry.phones, u.folder.keyFileOf(index, entry), s.passwordOf(entry), null)
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
