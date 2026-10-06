package ir.hamrasan.panel

import androidx.compose.runtime.Composable
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
import com.example.communication_super_app.smscrypto.keybank.Directory
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import ir.hamrasan.keybank.Activation
import ir.hamrasan.keybank.AuthorityFolder
import kotlinx.coroutines.runBlocking
import org.jetbrains.skia.EncodedImageFormat
import java.io.File
import java.nio.file.Files
import java.security.SecureRandom

/**
 * `HamresanPanel.exe --self-test <folder>`: checks the INSTALLED build — after
 * ProGuard, on its bundled Java — without a screen. It issues key files with
 * a throw-away authority, re-opens them as the app would, checks an
 * activation code against a phone-verified one, and renders the screens to
 * PNG. The verdict goes to `<folder>/self-test.txt` (the launcher has no console).
 */
object SelfTest {
    fun run(out: File): Boolean {
        out.mkdirs()
        val log = StringBuilder()
        val ok = try {
            check(Activation.activationCodeFor("b60966") == "9c4a48e93a") { "activation code differs from the app" }
            log.appendLine("activation: ok")

            val random = SecureRandom()
            val dir = Files.createTempDirectory("panel-self-test").toFile()
            try {
                val contents = AuthorityFile.Contents(AuthorityKey.generate(random), ByteArray(Directory.ID_BYTES).also(random::nextBytes))
                val password = "self-test-password"
                val authorityFile = File(dir, AuthorityFolder.AUTHORITY_FILE)
                authorityFile.writeBytes(AuthorityFile.create(contents, password, random))

                val keys = KeysState(rememberFile = false).apply {
                    this.authorityFile = authorityFile
                    this.password = password
                }
                runBlocking { keys.unlock() }
                check(keys.unlocked != null) { "unlock failed: ${keys.error}" }
                val form = MemberForm().apply { organization = "سازمان آزمون"; name = "عضو یک"; mobile = "09120000001" }
                runBlocking { keys.addMember(form) }
                form.apply { name = "عضو دو"; mobile = "09120000002"; deviceCode = "b60966" }
                runBlocking { keys.addMember(form) }
                val d = keys.delivery ?: error("no delivery: ${form.error}")
                val opened = KeyFile.open(d.file.readBytes(), d.password!!, listOf(contents.key.public))
                check(opened.directory.members.size == 2 && opened.memberIndex == 1) { "key file does not open as issued" }
                check(d.activationCode == "9c4a48e93a") { "delivery activation code" }
                log.appendLine("issue + open: ok")

                render(out, "keys-issued") { Panel(keys, start = Section.Keys) }
                keys.delivery = null
                render(out, "keys") { Panel(keys, start = Section.Keys) }
                render(out, "activation") { Panel(KeysState(rememberFile = false), activation = ActivationState().apply { input = "4f339b" }) }
                File(out, "sheet.html").writeText(DeliverySheet.html("سازمان آزمون", d))
                log.appendLine("render: ok")
            } finally {
                dir.deleteRecursively()
            }
            true
        } catch (e: Throwable) {
            log.appendLine("FAILED: $e")
            e.stackTrace.take(12).forEach { log.appendLine("  at $it") }
            false
        }
        log.appendLine(if (ok) "SELF-TEST PASSED" else "SELF-TEST FAILED")
        File(out, "self-test.txt").writeText(log.toString())
        return ok
    }

    private fun render(out: File, name: String, content: @Composable () -> Unit) {
        val scene = ImageComposeScene(1040, 720, Density(1f)) { PanelTheme(content) }
        var t = 0L
        repeat(6) { scene.render(t); t += 100_000_000L }
        File(out, "$name.png").writeBytes(scene.render(t).encodeToData(EncodedImageFormat.PNG)!!.bytes)
        scene.close()
    }
}
