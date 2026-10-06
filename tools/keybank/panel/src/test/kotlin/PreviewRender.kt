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

    @Test
    fun firstMember() {
        val (file, password) = authorityFolder(withMembers = false)
        val keys = KeysState(rememberFile = false).apply { authorityFile = file; this.password = password }
        runBlocking { keys.unlock() }
        render("08-keys-empty") { Panel(keys, start = Section.Keys) }
        file.parentFile.deleteRecursively()
    }
}
