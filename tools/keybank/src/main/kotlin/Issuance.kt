package ir.hamrasan.keybank

import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.Canon
import com.example.communication_super_app.smscrypto.keybank.Directory
import com.example.communication_super_app.smscrypto.keybank.Issuer
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import com.example.communication_super_app.smscrypto.keybank.PasswordKdf
import com.example.communication_super_app.smscrypto.keybank.UpdateFile
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
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
    const val UPDATE_FILE = "update.hku"

    /** One member's file as written. */
    class IssuedFile(val index: Int, val entry: Issuer.Entry, val file: File, val password: String) {
        val phone: String get() = entry.phones.first()
    }

    /**
     * Signs a directory of [roster] and writes one key file per member into
     * [out], with `passwords.csv`. A member in [known] (by default what
     * `passwords.csv` already says) keeps their password; their key never
     * changes (it is derived from their first number and generation), so
     * re-issuing only adds what is new.
     *
     * All or nothing: everything is written into a scratch folder first and
     * moved into place only once every file exists. A failure half-way used
     * to leave some files re-written — one of them, after «گوشی گم شد», under
     * a new password that `passwords.csv` (written last) did not have yet.
     */
    fun issue(
        authority: AuthorityFile.Contents,
        roster: Issuer.Roster,
        out: File,
        random: SecureRandom,
        serial: Long = System.currentTimeMillis(),
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        known: Map<String, String>? = null,
        progress: (done: Int, total: Int) -> Unit = { _, _ -> },
    ): List<IssuedFile> {
        out.mkdirs()
        val passwordsFile = File(out, PASSWORDS_FILE)
        val passwords = known ?: readPasswords(passwordsFile)
        val issued = Issuer.issue(authority.key, authority.directoryId, roster, serial, random)

        val scratch = File(out, SCRATCH_DIR)
        scratch.deleteRecursively()
        scratch.mkdirs()
        try {
            val files = roster.entries.mapIndexed { i, entry ->
                val phone = entry.phones.first()
                val password = passwords[phone] ?: Issuer.password(random)
                val name = fileName(i, phone)
                File(scratch, name).writeBytes(KeyFile.create(issued.signed, i to issued.identities[i], password, random, kdf))
                progress(i + 1, roster.entries.size)
                IssuedFile(i, entry, File(out, name), password)
            }
            val lines = mutableListOf("name,phone,file,password")
            files.forEach { lines += listOf(csv(it.entry.name), it.phone, it.file.name, it.password).joinToString(",") }
            // With a BOM, so Excel opens the Persian names as UTF-8.
            File(scratch, PASSWORDS_FILE).writeText("﻿" + lines.joinToString("\r\n") + "\r\n", Charsets.UTF_8)
            // The same signed directory for everyone, without anyone's key:
            // members whose own key did not change import it instead of their
            // file, with no password. See UpdateFile.kt.
            File(scratch, UPDATE_FILE).writeBytes(UpdateFile.create(issued.signed, authority.directoryId, random, kdf))

            // Every file exists: now they replace the old ones.
            for (f in files) move(File(scratch, f.file.name), f.file)
            move(File(scratch, UPDATE_FILE), File(out, UPDATE_FILE))
            move(File(scratch, PASSWORDS_FILE), passwordsFile)

            // A key file this round did not write carries an older directory (or
            // a member who left): when the roster's order changes, the same
            // member's file gets a new number and the old name would stay behind,
            // ready to be handed out by mistake. Only our own NNN-*.hkb names.
            val written = files.map { it.file.name }.toSet()
            out.listFiles { f -> f.isFile && OWN_FILE.matches(f.name) && f.name !in written }?.forEach { it.delete() }
            return files
        } finally {
            scratch.deleteRecursively()
        }
    }

    private fun move(from: File, to: File) {
        try {
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (e: java.nio.file.AtomicMoveNotSupportedException) {
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    private const val SCRATCH_DIR = ".issuing"
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
 * keep it: `authority.hka`, `roster.csv`, `issuance-log.csv`, and `issued/`
 * with the key files and `passwords.csv`. The panel works on this layout; the
 * command line takes explicit paths.
 *
 * Every change to the roster goes the same way: [prepare]-style validation
 * that writes nothing (the panel runs it before asking for confirmation), the
 * old roster kept under `backups/`, the new one written, every file
 * re-issued, the old roster put back if issuing throws, and one line in the
 * log.
 */
class AuthorityFolder(val dir: File) {
    val authorityFile = File(dir, AUTHORITY_FILE)
    val rosterFile = File(dir, ROSTER_FILE)
    val issuedDir = File(dir, ISSUED_DIR)
    val passwordsFile = File(issuedDir, Issuance.PASSWORDS_FILE)
    val updateFile = File(issuedDir, Issuance.UPDATE_FILE)
    val log = IssuanceLog(File(dir, IssuanceLog.FILE))

    class MemberError(message: String) : Exception(message)

    /** Where a member's phone stands, as far as the operator recorded. */
    enum class DeliveryStatus {
        /** Holds a file with the current directory and their current key. */
        CURRENT,

        /** Their key is current but the directory on their phone is older. */
        STALE,

        /** They were given a new key («گوشی گم شد») that has not been delivered. */
        NEW_KEY,

        /** No delivery recorded — a new member, or a folder from before the log. */
        NOT_RECORDED,
    }

    /** What the folder holds now: the organization (null before the first member) and the members. */
    class Snapshot(
        val organization: String?,
        val entries: List<Issuer.Entry>,
        val passwords: Map<String, String>,
        val log: List<IssuanceLog.Entry> = emptyList(),
        /** [IssuanceLog.fingerprint] of the roster; null while it has no member. */
        val fingerprint: String? = null,
    ) {
        fun passwordOf(entry: Issuer.Entry): String? = passwords[entry.phones.first()]

        fun statusOf(entry: Issuer.Entry): DeliveryStatus {
            val phone = entry.phones.first()
            val mine = log.filter { it.phone == phone }
            val full = mine.lastOrNull { it.action == IssuanceLog.Action.DELIVERED } ?: return DeliveryStatus.NOT_RECORDED
            if (full.generation != entry.generation) return DeliveryStatus.NEW_KEY
            val latest = mine.last {
                it.action == IssuanceLog.Action.DELIVERED || it.action == IssuanceLog.Action.UPDATE_DELIVERED
            }
            return if (latest.fingerprint == fingerprint) DeliveryStatus.CURRENT else DeliveryStatus.STALE
        }

        /** Members whose phone does not hold the current directory and key. */
        val outdated: List<Issuer.Entry> get() = entries.filter { statusOf(it) != DeliveryStatus.CURRENT }
    }

    fun snapshot(): Snapshot {
        val text = if (rosterFile.isFile) rosterFile.readText(Charsets.UTF_8) else ""
        val organization = organizationOf(text)
        val roster = if (text.removePrefix("﻿").lines().any { isMemberLine(it) }) Issuer.parseRoster(text) else null
        return Snapshot(
            organization,
            roster?.entries.orEmpty(),
            Issuance.readPasswords(passwordsFile),
            log.read(),
            roster?.let(IssuanceLog::fingerprint),
        )
    }

    fun keyFileOf(index: Int, entry: Issuer.Entry) = File(issuedDir, Issuance.fileName(index, entry.phones.first()))

    /**
     * A checked change, nothing written yet: the old roster text (null when
     * there is none), the new one, its parsed result, which member it is
     * about, and whether that member's key changes.
     */
    data class Prepared(
        val oldText: String?,
        val text: String,
        val roster: Issuer.Roster,
        val index: Int,
        val keyChanged: Boolean,
    )

    // ── Adding ───────────────────────────────────────────────────────────

    /**
     * Adds a member to `roster.csv` and re-issues every key file.
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
        val p = prepare(name, phones, organization)
        val entry = p.roster.entries[p.index]
        return commit(authority, p, random, kdf, progress, Issuance.readPasswords(passwordsFile)) { fp ->
            logEntry(IssuanceLog.Action.ADD, entry, p.roster.entries.size, fp)
        }
    }

    /**
     * Everything [addMember] checks, without writing anything. The panel runs
     * it before asking for confirmation, so a mistake is reported before the
     * operator has agreed to re-issue every file.
     *
     * A number that has had a key before (a member removed, a number moved)
     * starts at the next generation: a key, once retired, is never issued
     * again — it may still be on a phone that was lost.
     */
    fun prepare(name: String, phones: List<String>, organization: String? = null): Prepared {
        val cleanName = checkName(name)
        val numbers = checkNumbers(phones)
        val oldText = if (rosterFile.isFile) rosterFile.readText(Charsets.UTF_8) else null
        var text = oldText ?: ""
        if (organizationOf(text) == null) {
            val org = organization?.trim().orEmpty()
            if (org.isEmpty()) throw MemberError("نام سازمان لازم است.")
            if (org.any { it == '\n' || it == '\r' }) throw MemberError("نام سازمان باید یک خط باشد.")
            text = "organization,$org\r\nname,phones,generation\r\n" + text
        }
        if (text.isNotEmpty() && !text.endsWith("\n")) text += "\r\n"
        text += memberLine(cleanName, numbers, nextGeneration(numbers.first())) + "\r\n"
        val roster = parse(text)
        return Prepared(oldText, text, roster, roster.entries.size - 1, keyChanged = true)
    }

    // ── Editing ──────────────────────────────────────────────────────────

    /**
     * Checks an edit of member [index] without writing anything. Changing the
     * FIRST number changes the member's key (it is derived from it); any
     * other change keeps it.
     */
    fun prepareEdit(index: Int, name: String, phones: List<String>): Prepared {
        val (oldText, roster) = current()
        val old = roster.entries.getOrNull(index) ?: throw MemberError("این عضو دیگر در فهرست نیست.")
        val cleanName = checkName(name)
        val numbers = checkNumbers(phones)
        val keyChanged = numbers.first() != old.phones.first()
        val generation = if (keyChanged) nextGeneration(numbers.first()) else old.generation
        if (cleanName == old.name && numbers == old.phones) throw MemberError("چیزی تغییر نکرده است.")
        val text = replaceMemberLine(oldText, index, memberLine(cleanName, numbers, generation))
        return Prepared(oldText, text, parse(text), index, keyChanged)
    }

    /** Applies [prepareEdit]. A member whose first number changed keeps their password. */
    fun editMember(
        authority: AuthorityFile.Contents,
        index: Int,
        name: String,
        phones: List<String>,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        progress: (done: Int, total: Int) -> Unit = { _, _ -> },
    ): List<Issuance.IssuedFile> {
        val old = current().second.entries[index]
        val p = prepareEdit(index, name, phones)
        val entry = p.roster.entries[index]
        val known = Issuance.readPasswords(passwordsFile).toMutableMap()
        if (p.keyChanged) known[old.phones.first()]?.let { known[entry.phones.first()] = it }
        return commit(authority, p, random, kdf, progress, known) { fp ->
            logEntry(
                IssuanceLog.Action.EDIT, entry, p.roster.entries.size, fp,
                note = if (p.keyChanged) "شمارهٔ اول ${old.phones.first()} بود؛ کلید تازه" else "",
            )
        }
    }

    // ── A new key («گوشی گم شد») ─────────────────────────────────────────

    /** Checks giving member [index] a new key and a new password. */
    fun prepareNewKey(index: Int): Prepared {
        val (oldText, roster) = current()
        val old = roster.entries.getOrNull(index) ?: throw MemberError("این عضو دیگر در فهرست نیست.")
        val generation = maxOf(old.generation + 1, nextGeneration(old.phones.first()))
        val text = replaceMemberLine(oldText, index, memberLine(old.name, old.phones, generation))
        return Prepared(oldText, text, parse(text), index, keyChanged = true)
    }

    /**
     * A new key and a NEW password for member [index] — their phone is gone,
     * and the paper with the old password may have gone with it. Everyone
     * else keeps theirs; once they import the new directory, the old key is
     * no longer accepted from or used for this member.
     */
    fun newKey(
        authority: AuthorityFile.Contents,
        index: Int,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        progress: (done: Int, total: Int) -> Unit = { _, _ -> },
    ): List<Issuance.IssuedFile> {
        val p = prepareNewKey(index)
        val entry = p.roster.entries[index]
        val known = Issuance.readPasswords(passwordsFile) - entry.phones.first()
        return commit(authority, p, random, kdf, progress, known) { fp ->
            logEntry(IssuanceLog.Action.NEW_KEY, entry, p.roster.entries.size, fp)
        }
    }

    // ── Removing ─────────────────────────────────────────────────────────

    /** Checks removing member [index]; the last member cannot be removed. */
    fun prepareRemove(index: Int): Prepared {
        val (oldText, roster) = current()
        roster.entries.getOrNull(index) ?: throw MemberError("این عضو دیگر در فهرست نیست.")
        if (roster.entries.size == 1) {
            throw MemberError("آخرین عضو سازمان را نمی‌توان حذف کرد.")
        }
        val text = replaceMemberLine(oldText, index, null)
        return Prepared(oldText, text, parse(text), index, keyChanged = false)
    }

    /**
     * Removes member [index] and re-issues everyone else's file; the removed
     * member's file and password are gone from `issued/`. Until the others
     * import their new file, their phones still know the removed member.
     */
    fun removeMember(
        authority: AuthorityFile.Contents,
        index: Int,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        progress: (done: Int, total: Int) -> Unit = { _, _ -> },
    ): List<Issuance.IssuedFile> {
        val removed = current().second.entries[index]
        val p = prepareRemove(index)
        return commit(authority, p, random, kdf, progress, Issuance.readPasswords(passwordsFile)) { fp ->
            logEntry(IssuanceLog.Action.REMOVE, removed, p.roster.entries.size, fp)
        }
    }

    // ── Deliveries ───────────────────────────────────────────────────────

    /** Records that member [index] was handed their current key file. */
    fun markDelivered(index: Int) = markDelivered(listOf(index))

    /** Records that each of [indices] was handed their current key file. */
    fun markDelivered(indices: List<Int>) = mark(IssuanceLog.Action.DELIVERED, indices)

    /**
     * Records that each of [indices] imported the update file — the current
     * directory, not a new key: a member whose key changed still needs their
     * own file ([DeliveryStatus.NEW_KEY] stays).
     */
    fun markUpdated(indices: List<Int>) = mark(IssuanceLog.Action.UPDATE_DELIVERED, indices)

    private fun mark(action: IssuanceLog.Action, indices: List<Int>) {
        val s = snapshot()
        val fp = s.fingerprint ?: return
        log.append(indices.mapNotNull { s.entries.getOrNull(it) }.map {
            logEntry(action, it, s.entries.size, fp)
        })
    }

    // ── Internals ────────────────────────────────────────────────────────

    private fun current(): Pair<String, Issuer.Roster> {
        val text = if (rosterFile.isFile) rosterFile.readText(Charsets.UTF_8) else ""
        if (!text.removePrefix("﻿").lines().any { isMemberLine(it) }) throw MemberError("سازمان هنوز عضوی ندارد.")
        return text to parse(text)
    }

    private fun commit(
        authority: AuthorityFile.Contents,
        p: Prepared,
        random: SecureRandom,
        kdf: PasswordKdf,
        progress: (Int, Int) -> Unit,
        known: Map<String, String>,
        logLine: (fingerprint: String) -> IssuanceLog.Entry,
    ): List<Issuance.IssuedFile> {
        if (p.oldText != null) {
            val backups = File(dir, BACKUP_DIR).apply { mkdirs() }
            File(backups, "roster-${LocalDateTime.now().format(STAMP)}.csv").writeText(p.oldText, Charsets.UTF_8)
        }
        rosterFile.writeText(p.text, Charsets.UTF_8)
        val issued = try {
            Issuance.issue(authority, p.roster, issuedDir, random, kdf = kdf, known = known, progress = progress)
        } catch (e: Exception) {
            if (p.oldText != null) rosterFile.writeText(p.oldText, Charsets.UTF_8) else rosterFile.delete()
            throw e
        }
        // The files are issued; a log that cannot be written must not make
        // the operator think they were not.
        runCatching { log.append(listOf(logLine(IssuanceLog.fingerprint(p.roster)))) }
        return issued
    }

    private fun logEntry(
        action: IssuanceLog.Action,
        entry: Issuer.Entry,
        members: Int,
        fingerprint: String,
        note: String = "",
    ) = IssuanceLog.Entry(
        LocalDateTime.now().withNano(0), action, entry.name, entry.phones.first(), entry.generation,
        members, fingerprint, note,
    )

    /** 0 for a number never keyed before, else one past the highest generation it ever had. */
    private fun nextGeneration(phone: String): Int =
        log.read().filter { it.phone == phone }.maxOfOrNull { it.generation + 1 } ?: 0

    private fun checkName(name: String): String {
        val cleanName = name.trim()
        if (cleanName.isEmpty()) throw MemberError("نام عضو خالی است.")
        if (cleanName.any { it == ',' || it == '\t' || it == '\n' || it == '\r' || it == '"' } || cleanName.startsWith("#")) {
            throw MemberError("نام عضو نباید ویرگول انگلیسی (,)، گیومهٔ انگلیسی (\") یا # داشته باشد. ویرگول فارسی (،) اشکالی ندارد.")
        }
        return cleanName
    }

    private fun checkNumbers(phones: List<String>): List<String> {
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
        if (numbers.toSet().size != numbers.size) throw MemberError("یک شماره دو بار نوشته شده است.")
        return numbers
    }

    private fun memberLine(name: String, phones: List<String>, generation: Int) =
        "$name,${phones.joinToString(";")}" + if (generation > 0) ",$generation" else ""

    private fun parse(text: String): Issuer.Roster = try {
        Issuer.parseRoster(text)
    } catch (e: Issuer.RosterException) {
        throw MemberError(rosterMessage(e.message.orEmpty()))
    }

    /**
     * [text] with the line of member [index] replaced by [line] (removed when
     * null). Everything else — comments, the header, a hand-written
     * generation, the line endings — stays exactly as it was.
     */
    private fun replaceMemberLine(text: String, index: Int, line: String?): String {
        val pieces = text.split("\n").toMutableList()
        var seen = -1
        for (i in pieces.indices) {
            if (!isMemberLine(pieces[i].removePrefix("﻿"))) continue
            seen++
            if (seen != index) continue
            val cr = if (pieces[i].endsWith("\r")) "\r" else ""
            val bom = if (pieces[i].startsWith("﻿")) "﻿" else ""
            if (line == null) pieces.removeAt(i) else pieces[i] = bom + line + cr
            return pieces.joinToString("\n")
        }
        throw MemberError("این عضو دیگر در فهرست نیست.")
    }

    companion object {
        const val AUTHORITY_FILE = "authority.hka"
        const val ROSTER_FILE = "roster.csv"
        const val ISSUED_DIR = "issued"
        const val BACKUP_DIR = "backups"

        private val STAMP = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss-SSS")

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
