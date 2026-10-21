package ir.hamrasan.panel

import androidx.compose.runtime.Composable
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import com.example.communication_super_app.smscrypto.CertHandshake
import com.example.communication_super_app.smscrypto.Packet
import com.example.communication_super_app.smscrypto.Payload
import com.example.communication_super_app.smscrypto.Wire
import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
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
                val contents = AuthorityFile.Contents(AuthorityKey.generate(random))
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
                val firstFile = keys.unlocked!!.folder.keyFileOf(keys.snapshot!!.entries[0])
                val firstBytes = firstFile.readBytes()
                form.apply { name = "عضو دو"; mobile = "09120000002"; deviceCode = "b60966" }
                runBlocking { keys.addMember(form) }
                val d = keys.delivery ?: error("no delivery: ${form.error}")
                val opened = KeyFile.open(d.file.readBytes(), d.password!!, listOf(contents.key.public))
                check(opened.cert.phone == "09120000002" && d.index == 1) { "key file does not open as issued" }
                // The newcomer's file is theirs alone: the first member's file did not change.
                check(firstFile.readBytes().contentEquals(firstBytes)) { "another member's file was rewritten" }
                check(d.activationCode == "9c4a48e93a") { "delivery activation code" }
                log.appendLine("issue + open: ok")

                // The two members talk over their certificates alone, as two
                // phones would — two SMS parts each way.
                val anchors = listOf(contents.key.public)
                val snap = keys.snapshot!!
                val first = KeyFile.open(
                    keys.unlocked!!.folder.keyFileOf(snap.entries[0]).readBytes(),
                    snap.passwordOf(snap.entries[0])!!,
                    anchors,
                )
                check(first.cert.phone == "09120000001" && opened.cert.phone == "09120000002") { "certificates" }
                val started = CertHandshake.initiate(first.cert, random)
                val answered = CertHandshake.respond(
                    opened.identity, opened.cert, Wire.parse(started.wire) as Packet.Init, anchors, random,
                )
                val done = CertHandshake.complete(
                    first.identity, first.cert, started.pending, Wire.parse(answered.wire) as Packet.Response, anchors,
                )
                check(Wire.smsParts(started.wire) == 2 && Wire.smsParts(answered.wire) == 2) { "handshake size" }
                val hello = done.session.seal(Payload.text("سلام"))
                val heard = answered.session.open(Wire.parse(hello.wire) as Packet.Message)
                check((Payload.parse(heard.payload) as Payload.Text).text == "سلام") { "certificate session" }
                log.appendLine("certificate handshake: ok")

                runBlocking { keys.markAllDelivered() }
                check(keys.snapshot!!.outdated.isEmpty()) { "deliveries not recorded" }
                val oldPassword = keys.snapshot!!.passwordOf(keys.snapshot!!.entries[0])
                runBlocking { keys.newKey(0) }
                val renewed = keys.delivery ?: error("no new key: ${keys.notice?.text}")
                check(renewed.password != oldPassword) { "new key password" }
                KeyFile.open(renewed.file.readBytes(), renewed.password!!, listOf(contents.key.public))
                check(keys.statusOf(0) == AuthorityFolder.DeliveryStatus.NEW_KEY) { "new key status" }
                val edit = keys.editForm(1)!!.apply { name = "عضو دو ویرایش‌شده" }
                runBlocking { keys.editMember(1, edit) }
                check(keys.snapshot!!.entries[1].name == "عضو دو ویرایش‌شده") { "edit" }
                runBlocking { keys.removeMember(0) }
                check(keys.snapshot!!.entries.size == 1) { "remove: ${keys.notice?.text}" }
                check(keys.snapshot!!.log.map { it.action.code }.takeLast(3) == listOf("new-key", "edit", "remove")) { "log" }
                keys.notice = null
                log.appendLine("new key + edit + remove + log: ok")

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
