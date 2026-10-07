package ir.hamrasan.panel

import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import androidx.compose.runtime.Composable
import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
import com.example.communication_super_app.smscrypto.keybank.Directory
import com.example.communication_super_app.smscrypto.keybank.PasswordKdf
import ir.hamrasan.keybank.AuthorityFolder
import kotlinx.coroutines.runBlocking
import org.jetbrains.skia.EncodedImageFormat
import java.io.File
import java.nio.file.Files
import java.security.SecureRandom
import kotlin.test.Test

/**
 * Renders the panel's screens to `build/previews/` as PNG files without opening a
 * window — how the layout is reviewed, and a smoke test that every screen
 * composes. Not an assertion of pixels.
 */
class PreviewRender {
    private val out = File("build/previews").apply { mkdirs() }
    private val random = SecureRandom()
    private val cheap = PasswordKdf(iterations = 1, memoryKiB = 64, parallelism = 1)

    private fun render(name: String, content: @Composable () -> Unit) {
        val scene = ImageComposeScene(1040, 720, Density(1f)) { PanelTheme(content) }
        var t = 0L
        repeat(6) { scene.render(t); t += 100_000_000L }
        val image = scene.render(t)
        File(out, "$name.png").writeBytes(image.encodeToData(EncodedImageFormat.PNG)!!.bytes)
        scene.close()
    }

    private fun authorityFolder(withMembers: Boolean): Pair<File, String> {
        val dir = Files.createTempDirectory("panel-preview").toFile()
        val contents = AuthorityFile.Contents(AuthorityKey.generate(random), ByteArray(Directory.ID_BYTES).also(random::nextBytes))
        val password = "preview-password-1"
        File(dir, AuthorityFolder.AUTHORITY_FILE).writeBytes(AuthorityFile.create(contents, password, random, cheap))
        if (withMembers) {
            val folder = AuthorityFolder(dir)
            folder.addMember(contents, "علی رودی", listOf("09034853204"), random, "سازمان نمونه هم‌رسان", cheap)
            folder.addMember(contents, "گوشی دوم", listOf("09356455230"), random, kdf = cheap)
            folder.addMember(contents, "کاربر سوم", listOf("09981362436", "02188776655"), random, kdf = cheap)
        }
        return File(dir, AuthorityFolder.AUTHORITY_FILE) to password
    }

    @Test
    fun activation() {
        val state = ActivationState().apply {
            input = "ef10c7"
            history += "4f339b" to "6510c93974"
        }
        render("01-activation") { Panel(KeysState(rememberFile = false), start = Section.Activation, activation = state) }
        render("02-activation-bad") { Panel(KeysState(rememberFile = false), activation = ActivationState().apply { input = "4f33xb" }) }
    }

    @Test
    fun keys() {
        val (file, password) = authorityFolder(withMembers = true)
        val locked = KeysState(rememberFile = false).apply { authorityFile = file; this.password = "wrong"; error = "رمز مرجع اشتباه است." }
        render("03-keys-locked") { Panel(locked, start = Section.Keys) }

        val keys = KeysState(rememberFile = false).apply { authorityFile = file; this.password = password }
        runBlocking { keys.unlock() }
        render("04-keys-unlocked") { Panel(keys, start = Section.Keys) }

        val form = MemberForm().apply { name = "کاربر چهارم"; mobile = "09332639135"; deviceCode = "4f339b" }
        runBlocking { keys.addMember(form) }
        render("05-keys-issued") { Panel(keys, start = Section.Keys) }

        keys.delivery = null
        keys.showMember(0)
        render("06-member") { Panel(keys, start = Section.Keys) }

        File("build/previews/07-sheet.html").writeText(DeliverySheet.html("سازمان نمونه هم‌رسان", keys.delivery!!))
        file.parentFile.deleteRecursively()
    }

    @Test
    fun idleLockDropsTheAuthority() {
        val (file, password) = authorityFolder(withMembers = false)
        val keys = KeysState(rememberFile = false, idleLockMs = 400).apply { authorityFile = file; this.password = password }
        runBlocking { keys.unlock() }
        kotlin.test.assertNotNull(keys.unlocked)
        val scene = ImageComposeScene(1040, 720, Density(1f)) { PanelTheme { Panel(keys, start = Section.Keys) } }
        scene.render(0)
        Thread.sleep(150)
        keys.touch() // activity restarts the clock
        scene.render(1)
        Thread.sleep(300)
        kotlin.test.assertNotNull(keys.unlocked, "locked although there was activity")
        Thread.sleep(600)
        scene.render(2)
        kotlin.test.assertNull(keys.unlocked, "still unlocked after the idle time")
        scene.close()
        file.parentFile.deleteRecursively()
    }

    @Test
    fun checkRunsBeforeAnythingIsWritten() {
        val (file, password) = authorityFolder(withMembers = true)
        val keys = KeysState(rememberFile = false).apply { authorityFile = file; this.password = password }
        runBlocking { keys.unlock() }
        val roster = File(file.parentFile, "roster.csv").readText()
        val form = MemberForm().apply { name = "تکراری"; mobile = "+98 903 485 3204" }
        kotlin.test.assertFalse(keys.check(form))
        kotlin.test.assertTrue(form.error!!.contains("09034853204"))
        form.apply { mobile = "02188776655" }
        kotlin.test.assertFalse(keys.check(form))
        form.apply { mobile = "09120000009"; deviceCode = "zz" }
        kotlin.test.assertFalse(keys.check(form))
        form.apply { deviceCode = "4F3-39B" }
        kotlin.test.assertTrue(keys.check(form), form.error)
        kotlin.test.assertEquals(roster, File(file.parentFile, "roster.csv").readText())
        file.parentFile.deleteRecursively()
    }

    @Test
    fun otherNumbersAreSplitTheWayPeopleWriteThem() {
        fun phones(others: String) = MemberForm().apply { mobile = "09120000001"; this.others = others }.phones().drop(1)
        kotlin.test.assertEquals(listOf("021 8877 6655"), phones("021 8877 6655"))
        kotlin.test.assertEquals(listOf("021 8877 6655", "0912 111 2233"), phones("021 8877 6655؛ 0912 111 2233"))
        kotlin.test.assertEquals(listOf("02188776655", "09121112233"), phones("02188776655, 09121112233"))
        kotlin.test.assertEquals(listOf("09121112233", "09351112233"), phones("09121112233 09351112233"))
        kotlin.test.assertEquals(emptyList(), phones("  "))
    }

    @Test
    fun jalaliMatchesTheApp() {
        kotlin.test.assertEquals("1405/07/13 16:37", jalaliNow(java.time.LocalDateTime.of(2026, 10, 5, 16, 37)))
        kotlin.test.assertEquals("1403/01/01 00:00", jalaliNow(java.time.LocalDateTime.of(2024, 3, 20, 0, 0)))
    }

    private fun unlocked(withMembers: Boolean = true): Pair<KeysState, File> {
        val (file, password) = authorityFolder(withMembers)
        val keys = KeysState(rememberFile = false).apply { authorityFile = file; this.password = password }
        runBlocking { keys.unlock() }
        return keys to file.parentFile
    }

    @Test
    fun whoHoldsAnOldFile() {
        val (keys, dir) = unlocked()
        // A folder from before the log: nobody's delivery is recorded.
        kotlin.test.assertEquals(3, keys.snapshot!!.outdated.size)
        render("09-not-recorded") { Panel(keys, start = Section.Keys) }
        runBlocking { keys.markAllDelivered() }
        kotlin.test.assertTrue(keys.snapshot!!.outdated.isEmpty())

        runBlocking { keys.addMember(MemberForm().apply { name = "کاربر چهارم"; mobile = "09332639135" }) }
        keys.delivery = null
        val s = keys.snapshot!!
        kotlin.test.assertEquals(
            listOf(AuthorityFolder.DeliveryStatus.STALE, AuthorityFolder.DeliveryStatus.STALE, AuthorityFolder.DeliveryStatus.STALE, AuthorityFolder.DeliveryStatus.NOT_RECORDED),
            s.entries.map(s::statusOf),
        )
        render("10-stale") { Panel(keys, start = Section.Keys) }

        keys.showMember(0)
        render("11-member-stale") { Panel(keys, start = Section.Keys) }
        runBlocking { keys.markDelivered(0) }
        kotlin.test.assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, keys.statusOf(0))
        render("12-member-delivered") { Panel(keys, start = Section.Keys) }
        keys.delivery = null

        keys.view = KeysState.View.LOG
        render("13-log") { Panel(keys, start = Section.Keys) }
        kotlin.test.assertEquals(
            listOf("add", "add", "add", "delivered", "delivered", "delivered", "add", "delivered"),
            keys.snapshot!!.log.map { it.action.code },
        )
        keys.dialog = KeysState.Dialog.MarkAll(update = false)
        keys.view = KeysState.View.MEMBERS
        render("14-confirm-mark-all") { Panel(keys, start = Section.Keys) }
        dir.deleteRecursively()
    }

    @Test
    fun theUpdateFile() {
        val (keys, dir) = unlocked()
        runBlocking { keys.markAllDelivered() }
        runBlocking { keys.addMember(MemberForm().apply { name = "کاربر چهارم"; mobile = "09332639135" }) }
        keys.delivery = null
        val update = File(dir, "issued/update.hku")
        kotlin.test.assertTrue(update.isFile)
        val opened = com.example.communication_super_app.smscrypto.keybank.UpdateFile.open(
            update.readBytes(),
            listOf(keys.unlocked!!.contents.directoryId),
            listOf(keys.unlocked!!.contents.key.public),
        )
        kotlin.test.assertEquals(4, opened.directory.members.size)
        render("21-update-banner") { Panel(keys, start = Section.Keys) }
        keys.dialog = KeysState.Dialog.MarkAll(update = true)
        render("22-confirm-mark-updated") { Panel(keys, start = Section.Keys) }
        keys.dialog = null
        runBlocking { keys.markAllUpdated() }
        // The three who had the old file are current; the newcomer still needs theirs.
        kotlin.test.assertEquals(listOf("کاربر چهارم"), keys.snapshot!!.outdated.map { it.name })
        render("23-after-update") { Panel(keys, start = Section.Keys) }
        dir.deleteRecursively()
    }

    @Test
    fun lostPhone() {
        val (keys, dir) = unlocked()
        runBlocking { keys.markAllDelivered() }
        val oldPassword = keys.snapshot!!.let { it.passwordOf(it.entries[1]) }
        keys.dialog = KeysState.Dialog.NewKey(1)
        render("15-confirm-new-key") { Panel(keys, start = Section.Keys) }
        keys.dialog = null
        kotlin.test.assertNull(keys.checkNewKey(1))
        runBlocking { keys.newKey(1) }
        val d = keys.delivery!!
        kotlin.test.assertEquals(KeysState.Event.NEW_KEY, d.event)
        kotlin.test.assertNotEquals(oldPassword, d.password)
        kotlin.test.assertEquals(1, keys.snapshot!!.entries[1].generation)
        kotlin.test.assertEquals(AuthorityFolder.DeliveryStatus.NEW_KEY, keys.statusOf(1))
        kotlin.test.assertEquals(AuthorityFolder.DeliveryStatus.STALE, keys.statusOf(0))
        render("16-new-key-issued") { Panel(keys, start = Section.Keys) }
        dir.deleteRecursively()
    }

    @Test
    fun editAndRemove() {
        val (keys, dir) = unlocked()
        val form = keys.editForm(2)!!
        kotlin.test.assertEquals("09981362436", form.mobile)
        kotlin.test.assertEquals(listOf("09981362436", "02188776655"), form.phones())
        form.mobile = "09121112233"
        keys.dialog = KeysState.Dialog.Edit(2, form)
        render("17-edit") { Panel(keys, start = Section.Keys) }
        kotlin.test.assertEquals(true, keys.checkEdit(2, form))
        keys.dialog = null
        val oldPassword = keys.snapshot!!.let { it.passwordOf(it.entries[2]) }
        runBlocking { keys.editMember(2, form) }
        kotlin.test.assertEquals(KeysState.Event.EDITED, keys.delivery!!.event)
        kotlin.test.assertEquals(oldPassword, keys.delivery!!.password)
        kotlin.test.assertEquals(listOf("09121112233", "02188776655"), keys.snapshot!!.entries[2].phones)
        render("18-edited") { Panel(keys, start = Section.Keys) }
        keys.delivery = null

        // A mistake stays in the form and nothing is written.
        val roster = File(dir, "roster.csv").readText()
        val bad = keys.editForm(0)!!.apply { mobile = "09356455230" }
        kotlin.test.assertNull(keys.checkEdit(0, bad))
        kotlin.test.assertTrue(bad.error!!.contains("09356455230"))
        kotlin.test.assertEquals(roster, File(dir, "roster.csv").readText())

        keys.dialog = KeysState.Dialog.Remove(1)
        render("19-confirm-remove") { Panel(keys, start = Section.Keys) }
        keys.dialog = null
        runBlocking { keys.removeMember(1) }
        kotlin.test.assertNotNull(keys.notice)
        kotlin.test.assertEquals(listOf("علی رودی", "کاربر سوم"), keys.snapshot!!.entries.map { it.name })
        render("20-removed") { Panel(keys, start = Section.Keys) }
        keys.notice = null
        runBlocking { keys.removeMember(0) }
        keys.notice = null
        kotlin.test.assertNotNull(keys.checkRemove(0), "the last member cannot be removed")
        dir.deleteRecursively()
    }

    /**
     * The confirmation's own button, pressed in a rendered scene — not the
     * state called directly, which is how every other test here works and
     * why none saw this: the dialog started the job in its own scope, closed
     * itself, and the job died half-way while the files were already issued.
     */
    @Test
    fun aConfirmedChangeRunsToTheEnd() {
        val (keys, dir) = unlocked()
        runBlocking { keys.markAllDelivered() }
        val oldPassword = keys.snapshot!!.let { it.passwordOf(it.entries[1]) }
        keys.dialog = KeysState.Dialog.NewKey(1)
        val scene = ImageComposeScene(1040, 720, Density(1f)) { PanelTheme { Panel(keys, start = Section.Keys) } }
        var t = 0L
        repeat(6) { scene.render(t); t += 100_000_000L }
        // «ساخت کلید و رمز تازه», where 15-confirm-new-key.png draws it.
        val button = androidx.compose.ui.geometry.Offset(345f, 455f)
        scene.sendPointerEvent(androidx.compose.ui.input.pointer.PointerEventType.Press, button)
        scene.sendPointerEvent(androidx.compose.ui.input.pointer.PointerEventType.Release, button)
        val deadline = System.currentTimeMillis() + 60_000
        while (keys.delivery == null && keys.notice == null && System.currentTimeMillis() < deadline) {
            scene.render(t); t += 50_000_000L
            Thread.sleep(50)
        }
        scene.close()
        kotlin.test.assertNull(keys.notice?.text, "the change was reported as failed")
        val d = kotlin.test.assertNotNull(keys.delivery, "nothing came back")
        kotlin.test.assertEquals(KeysState.Event.NEW_KEY, d.event)
        kotlin.test.assertNotEquals(oldPassword, d.password)
        kotlin.test.assertEquals(AuthorityFolder.DeliveryStatus.NEW_KEY, keys.statusOf(1))
        dir.deleteRecursively()
    }

    /** The operator names the folder; a Persian name with spaces, on a Persian-named file, must work. */
    @Test
    fun aFolderAndFileWithPersianNames() {
        val root = Files.createTempDirectory("panel-fa").toFile()
        val dir = File(root, "مرجع سازمان ما").apply { mkdirs() }
        val contents = AuthorityFile.Contents(AuthorityKey.generate(random), ByteArray(Directory.ID_BYTES).also(random::nextBytes))
        val file = File(dir, "کلید سازمان.hka").apply { writeBytes(AuthorityFile.create(contents, "persian-path-pw", random, cheap)) }
        val keys = KeysState(rememberFile = false).apply { authorityFile = file; password = "persian-path-pw" }
        runBlocking { keys.unlock() }
        kotlin.test.assertNotNull(keys.unlocked, keys.error)
        runBlocking { keys.addMember(MemberForm().apply { organization = "سازمان تست"; name = "علی"; mobile = "09120000001" }) }
        val d = kotlin.test.assertNotNull(keys.delivery, keys.notice?.text)
        kotlin.test.assertTrue(d.file.isFile)
        kotlin.test.assertTrue(File(dir, "issued/update.hku").isFile)
        kotlin.test.assertTrue(File(dir, "issuance-log.csv").isFile)
        runBlocking { keys.markDelivered(0) }
        kotlin.test.assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, keys.statusOf(0))
        kotlin.test.assertNotNull(keys.deliverySheet(d)?.takeIf { it.isFile })
        root.deleteRecursively()
    }

    @Test
    fun firstMember() {
        val (file, password) = authorityFolder(withMembers = false)
        val keys = KeysState(rememberFile = false).apply { authorityFile = file; this.password = password }
        runBlocking { keys.unlock() }
        render("08-keys-empty") { Panel(keys, start = Section.Keys) }
        file.parentFile.deleteRecursively()
    }
}
