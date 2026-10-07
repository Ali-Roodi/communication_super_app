package ir.hamrasan.keybank

import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
import com.example.communication_super_app.smscrypto.keybank.AuthorityPublic
import com.example.communication_super_app.smscrypto.keybank.Directory
import com.example.communication_super_app.smscrypto.keybank.Issuer
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import java.io.File
import java.security.SecureRandom
import kotlin.system.exitProcess

/**
 * هم‌رسان key-bank tool — the authority's side of «بانک کلید». See README.md.
 *
 *   init    <authority.hka>
 *   public  <authority.hka>
 *   issue   <authority.hka> <roster.csv> <output folder>
 *   inspect <key file .hkb> <authority public key .txt>
 *   activation <device code>
 *
 * Passwords are asked on the console; HAMRESAN_KEYBANK_PASSWORD (authority
 * file) and HAMRESAN_KEYFILE_PASSWORD (inspect) are read instead when set,
 * for scripted use.
 */
private val random = SecureRandom()

fun main(args: Array<String>) {
    try {
        when (args.firstOrNull()) {
            "init" -> init(args)
            "public" -> public(args)
            "issue" -> issue(args)
            "inspect" -> inspect(args)
            "activation" -> activation(args)
            else -> usage()
        }
    } catch (e: SmsCryptoException) {
        fail(
            when (e.code) {
                SmsCryptoException.Code.WRONG_PASSWORD -> "wrong password"
                SmsCryptoException.Code.NOT_A_KEY_FILE -> "not a file of this tool"
                SmsCryptoException.Code.UNTRUSTED -> "signed by another authority"
                SmsCryptoException.Code.BAD_SIGNATURE -> "the signature does not verify — the file was altered"
                else -> "${e.code}: ${e.message}"
            },
        )
    } catch (e: Issuer.RosterException) {
        fail("roster: ${e.message}")
    }
}

private fun usage(): Nothing {
    println(
        """
        hamresan-keybank — key bank for هم‌رسان encrypted SMS

          init    <authority.hka>
                  Creates the authority: its signing keys and the seed every
                  member key is derived from. Keep this file offline, with a
                  backup — whoever has it and its password issues keys.
          public  <authority.hka>
                  Prints the authority public key. It goes into the app once
                  (lib/features/keybank/trust_anchors.dart).
          issue   <authority.hka> <roster.csv> <output folder>
                  One key file per member, and passwords.csv. Roster lines:
                  organization,<name>, then name,phone1;phone2[,generation].
                  Re-issuing keeps every
                  member's key; raise a member's generation to replace theirs.
                  Existing passwords in passwords.csv are reused.
          inspect <file.hkb> <authority-public.txt>
                  Opens and verifies a key file.
          activation <device code>
                  The inter-organizational activation code for the 6-character
                  device code a phone shows. Needs no authority.

        The roster is UTF-8 (Excel: «CSV UTF-8»); its first line names the
        organization: organization,<name>. For Persian text in the console,
        run `chcp 65001` first.
        """.trimIndent(),
    )
    exitProcess(2)
}

private fun fail(message: String): Nothing {
    System.err.println("error: $message")
    exitProcess(1)
}

private fun password(env: String, prompt: String): String {
    System.getenv(env)?.let { return it }
    val console = System.console()
    if (console != null) return String(console.readPassword(prompt) ?: fail("no password"))
    print(prompt)
    return readLine() ?: fail("no password")
}

private fun init(args: Array<String>) {
    if (args.size != 2) usage()
    val file = File(args[1])
    if (file.exists()) fail("${file.path} exists — refusing to overwrite an authority")
    val first = password("HAMRESAN_KEYBANK_PASSWORD", "New authority password (${AuthorityFile.MIN_PASSWORD_LENGTH}+ characters): ")
    if (first.length < AuthorityFile.MIN_PASSWORD_LENGTH) fail("password too short")
    if (System.getenv("HAMRESAN_KEYBANK_PASSWORD") == null) {
        if (password("-", "Repeat it: ") != first) fail("the passwords differ")
    }
    val contents = AuthorityFile.Contents(
        AuthorityKey.generate(random),
        ByteArray(Directory.ID_BYTES).also(random::nextBytes),
    )
    file.writeBytes(AuthorityFile.create(contents, first, random))
    println("Authority created: ${file.path}")
    println("Authority id: ${hex(contents.key.public.authorityId)}")
    println("Next: `public` prints the key to put into the app.")
}

private fun openAuthority(path: String): AuthorityFile.Contents {
    val file = File(path)
    if (!file.isFile) fail("no such file: $path")
    return AuthorityFile.open(file.readBytes(), password("HAMRESAN_KEYBANK_PASSWORD", "Authority password: "))
}

private fun public(args: Array<String>) {
    if (args.size != 2) usage()
    val authority = openAuthority(args[1])
    println("Authority id: ${hex(authority.key.public.authorityId)}")
    println("Public key (${AuthorityPublic.ENCODED_BYTES} bytes, hex):")
    println(hex(authority.key.public.encoded))
}

private fun issue(args: Array<String>) {
    if (args.size != 4) usage()
    val authority = openAuthority(args[1])
    val roster = Issuer.parseRoster(File(args[2]).readText(Charsets.UTF_8))
    val out = File(args[3])
    Issuance.issue(authority, roster, out, random) { done, total ->
        val phone = roster.entries[done - 1].phones.first()
        println("  $done/$total  $phone  ${Issuance.fileName(done - 1, phone)}")
    }
    println("Issued ${roster.entries.size} key files for ${roster.organization} to ${out.path}; passwords in ${Issuance.PASSWORDS_FILE}.")
    println("Hand each member their file and, separately, its password.")
    println("${Issuance.UPDATE_FILE}: the same directory without anyone's key, for members who already")
    println("imported a file of this organization and whose key did not change - no password needed.")
}

private fun activation(args: Array<String>) {
    if (args.size != 2) usage()
    val device = Activation.normalizeDeviceCode(args[1]) ?: fail("a device code is 6 hex characters, e.g. 4f339b")
    println(Activation.activationCodeFor(device))
}

private fun inspect(args: Array<String>) {
    if (args.size != 3) usage()
    val anchor = AuthorityPublic.parse(unhex(File(args[2]).readText().trim()))
    val opened = KeyFile.open(
        File(args[1]).readBytes(),
        password("HAMRESAN_KEYFILE_PASSWORD", "Key file password: "),
        listOf(anchor),
    )
    val d = opened.directory
    println("Organization: ${d.name}")
    println("Issued: ${java.time.Instant.ofEpochMilli(d.serial)}  members: ${d.members.size}")
    d.members.forEachIndexed { i, m ->
        val mark = if (i == opened.memberIndex) " ← this file's owner" else ""
        println("  ${i + 1}. ${m.name}  ${m.phones.joinToString(" ")}  key ${hex(m.identity.keyId)}$mark")
    }
    println("Signature: valid")
}

private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

private fun unhex(text: String): ByteArray {
    if (text.length % 2 != 0) fail("not a hex key")
    return ByteArray(text.length / 2) { i ->
        text.substring(2 * i, 2 * i + 2).toIntOrNull(16)?.toByte() ?: fail("not a hex key")
    }
}
