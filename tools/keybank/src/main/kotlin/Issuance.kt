package ir.hamrasan.keybank

import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.Canon
import com.example.communication_super_app.smscrypto.keybank.Directory
import com.example.communication_super_app.smscrypto.keybank.Issuer
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import com.example.communication_super_app.smscrypto.keybank.PasswordKdf
import java.io.File
import java.security.SecureRandom
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * Issuing key files into a folder — shared by the command line (`issue`) and
 * the issuance panel, so both write the same files and the same
 * `passwords.csv`.
 */
object Issuance {
    const val PASSWORDS_FILE = "passwords.csv"

    /** One member's file as written. */
    class IssuedFile(val index: Int, val entry: Issuer.Entry, val file: File, val password: String) {
        val phone: String get() = entry.phones.first()
    }

    /**
     * Signs a directory of [roster] and writes one key file per member into
     * [out], with `passwords.csv`. A member already in `passwords.csv` keeps
     * their password; their key never changes (it is derived from their first
     * number and generation), so re-issuing only adds what is new.
     */
    fun issue(
        authority: AuthorityFile.Contents,
        roster: Issuer.Roster,
        out: File,
        random: SecureRandom,
        serial: Long = System.currentTimeMillis(),
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        progress: (done: Int, total: Int) -> Unit = { _, _ -> },
    ): List<IssuedFile> {
        out.mkdirs()
        val passwordsFile = File(out, PASSWORDS_FILE)
        val known = readPasswords(passwordsFile)
        val issued = Issuer.issue(authority.key, authority.directoryId, roster, serial, random)
        val files = roster.entries.mapIndexed { i, entry ->
            val phone = entry.phones.first()
            val password = known[phone] ?: Issuer.password(random)
            val file = File(out, fileName(i, phone))
            file.writeBytes(KeyFile.create(issued.signed, i to issued.identities[i], password, random, kdf))
            progress(i + 1, roster.entries.size)
            IssuedFile(i, entry, file, password)
        }
        val lines = mutableListOf("name,phone,file,password")
        files.forEach { lines += listOf(csv(it.entry.name), it.phone, it.file.name, it.password).joinToString(",") }
        // With a BOM, so Excel opens the Persian names as UTF-8.
        passwordsFile.writeText("﻿" + lines.joinToString("\r\n") + "\r\n", Charsets.UTF_8)
        // A key file this round did not write carries an older directory (or
        // a member who left): when the roster's order changes, the same
        // member's file gets a new number and the old name would stay behind,
        // ready to be handed out by mistake. Only our own NNN-*.hkb names.
        val written = files.map { it.file.name }.toSet()
        out.listFiles { f -> f.isFile && OWN_FILE.matches(f.name) && f.name !in written }?.forEach { it.delete() }
        return files
    }

    private val OWN_FILE = Regex("""\d{3}-[0-9]+\.hkb""")

    fun fileName(index: Int, phone: String) = "%03d-%s.hkb".format(index + 1, phone)

    /** `passwords.csv` as phone → password; empty when there is none yet. */
    fun readPasswords(file: File): Map<String, String> {
        if (!file.isFile) return emptyMap()
        return file.readText(Charsets.UTF_8).removePrefix("﻿").lines().drop(1)
            .mapNotNull { line ->
                val f = line.split(',')
                // name may itself hold commas (quoted); the last three fields do not.
                if (f.size >= 4) f[f.size - 3].trim() to f[f.size - 1].trim() else null
            }.toMap()
    }

    private fun csv(value: String) =
        if (',' in value || '"' in value) "\"" + value.replace("\"", "\"\"") + "\"" else value
}

/**
 * The authority's folder, laid out the way the README tells the operator to
 * keep it: `authority.hka`, `roster.csv`, and `issued/` with the key files and
 * `passwords.csv`. The panel works on this layout; the command line takes
 * explicit paths.
 */
class AuthorityFolder(val dir: File) {
    val authorityFile = File(dir, AUTHORITY_FILE)
    val rosterFile = File(dir, ROSTER_FILE)
    val issuedDir = File(dir, ISSUED_DIR)
    val passwordsFile = File(issuedDir, Issuance.PASSWORDS_FILE)

    class MemberError(message: String) : Exception(message)

    /** What the folder holds now: the organization (null before the first member) and the members. */
    class Snapshot(val organization: String?, val entries: List<Issuer.Entry>, val passwords: Map<String, String>) {
        fun passwordOf(entry: Issuer.Entry): String? = passwords[entry.phones.first()]
    }

    fun snapshot(): Snapshot {
        val text = if (rosterFile.isFile) rosterFile.readText(Charsets.UTF_8) else ""
        val organization = organizationOf(text)
        val entries = if (text.lines().any { isMemberLine(it) }) Issuer.parseRoster(text).entries else emptyList()
        return Snapshot(organization, entries, Issuance.readPasswords(passwordsFile))
    }

    fun keyFileOf(index: Int, entry: Issuer.Entry) = File(issuedDir, Issuance.fileName(index, entry.phones.first()))

    /**
     * Adds a member to `roster.csv` and re-issues every key file. The roster
     * is validated with the new line before anything is written, the old
     * roster is kept under `backups/`, and it is put back if issuing fails.
     *
     * [organization] is only used when there is no roster yet.
     */
    fun addMember(
        authority: AuthorityFile.Contents,
        name: String,
        phones: List<String>,
        random: SecureRandom,
        organization: String? = null,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        progress: (done: Int, total: Int) -> Unit = { _, _ -> },
    ): List<Issuance.IssuedFile> {
        val (oldText, text, roster) = prepare(name, phones, organization)
        if (oldText != null) {
            val backups = File(dir, BACKUP_DIR).apply { mkdirs() }
            File(backups, "roster-${LocalDateTime.now().format(STAMP)}.csv").writeText(oldText, Charsets.UTF_8)
        }
        rosterFile.writeText(text, Charsets.UTF_8)
        try {
            return Issuance.issue(authority, roster, issuedDir, random, kdf = kdf, progress = progress)
        } catch (e: Exception) {
            if (oldText != null) rosterFile.writeText(oldText, Charsets.UTF_8) else rosterFile.delete()
            throw e
        }
    }

    /**
     * Everything [addMember] checks, without writing anything: the old roster
     * text (null when there is none), the new one, and the parsed result.
     * The panel runs it before asking for confirmation, so a mistake is
     * reported before the operator has agreed to re-issue every file.
     */
    fun prepare(name: String, phones: List<String>, organization: String? = null): Triple<String?, String, Issuer.Roster> {
        val cleanName = name.trim()
        if (cleanName.isEmpty()) throw MemberError("نام عضو خالی است.")
        if (cleanName.any { it == ',' || it == '\t' || it == '\n' || it == '\r' } || cleanName.startsWith("#")) {
            throw MemberError("نام عضو نباید ویرگول انگلیسی (,) یا # داشته باشد. ویرگول فارسی (،) اشکالی ندارد.")
        }
        val numbers = phones.map { it.trim() }.filter { it.isNotEmpty() }.map { raw ->
            // The input goes last: Latin text between «» inside a Persian
            // sentence is reordered by bidi (and Compose ignores isolates).
            Canon.phone(raw) ?: throw MemberError("این شماره درست نیست: $raw")
        }
        if (numbers.isEmpty()) throw MemberError("دست‌کم یک شماره لازم است.")
        // The first number is where encrypted SMS goes and what the key is
        // derived from: it has to be a mobile (or a foreign number).
        val first = numbers.first()
        if (!(first.startsWith("09") && first.length == 11) && !first.startsWith("00")) {
            throw MemberError("شمارهٔ همراه باید با ۰۹ شروع شود و ۱۱ رقم باشد. شمارهٔ ثابت را در «شماره‌های دیگر» بنویسید.")
        }
        if (numbers.size > Directory.MAX_PHONES) throw MemberError("حداکثر ${Directory.MAX_PHONES} شماره برای هر عضو.")

        val oldText = if (rosterFile.isFile) rosterFile.readText(Charsets.UTF_8) else null
        var text = oldText ?: ""
        if (organizationOf(text) == null) {
            val org = organization?.trim().orEmpty()
            if (org.isEmpty()) throw MemberError("نام سازمان لازم است.")
            if (org.any { it == '\n' || it == '\r' }) throw MemberError("نام سازمان باید یک خط باشد.")
            text = "organization,$org\r\nname,phones,generation\r\n" + text
        }
        if (text.isNotEmpty() && !text.endsWith("\n")) text += "\r\n"
        text += cleanName + "," + numbers.joinToString(";") + "\r\n"

        val roster = try {
            Issuer.parseRoster(text)
        } catch (e: Issuer.RosterException) {
            throw MemberError(rosterMessage(e.message.orEmpty()))
        }
        return Triple(oldText, text, roster)
    }

    companion object {
        const val AUTHORITY_FILE = "authority.hka"
        const val ROSTER_FILE = "roster.csv"
        const val ISSUED_DIR = "issued"
        const val BACKUP_DIR = "backups"

        private val STAMP = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss")

        /** The same rule as `Issuer.parseRoster` for the organization line. */
        fun organizationOf(text: String): String? = text.removePrefix("﻿").lines().asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .map { it.split(if ('\t' in it) '\t' else ',').map(String::trim) }
            .firstOrNull { it[0].lowercase() in setOf("organization", "سازمان") }
            ?.drop(1)?.joinToString(",")?.trim()?.ifEmpty { null }

        private fun isMemberLine(raw: String): Boolean {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) return false
            val first = line.split(if ('\t' in line) '\t' else ',')[0].trim().lowercase()
            return first !in setOf("organization", "سازمان", "name", "نام")
        }

        /** The parser's English messages, for the one case a person can cause from the form. */
        private fun rosterMessage(message: String): String {
            val duplicate = Regex("(\\d+) is already on line (\\d+)").find(message)
            return if (duplicate != null) {
                "شمارهٔ ${duplicate.groupValues[1]} قبلاً برای عضو دیگری ثبت شده است."
            } else {
                "فهرست اعضا (roster.csv) مشکل دارد: $message"
            }
        }
    }
}
