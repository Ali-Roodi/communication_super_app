package ir.hamrasan.keybank

import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.Canon
import com.example.communication_super_app.smscrypto.keybank.Issuer
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import com.example.communication_super_app.smscrypto.keybank.MemberCert
import com.example.communication_super_app.smscrypto.keybank.PasswordKdf
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
 *
 * A key file holds its member's own key and certificate and nothing about
 * anybody else, so a member's file depends on that member alone: adding,
 * editing or re-keying one member writes one file, and every other member's
 * file — and phone — stays exactly as it was.
 */
object Issuance {
    const val PASSWORDS_FILE = "passwords.csv"

    /** One member's file as written. */
    class IssuedFile(val entry: Issuer.Entry, val file: File, val password: String) {
        val phone: String get() = entry.phones.first()
    }

    /**
     * Writes a key file for every member of [roster] into [out], with
     * `passwords.csv`. A member in [known] (by default what
     * `passwords.csv` already says) keeps their password; their key never
     * changes (it is derived from their first number and generation).
     *
     * All or nothing: everything is written into a scratch folder first and
     * moved into place only once every file exists.
     */
    fun issue(
        authority: AuthorityFile.Contents,
        roster: Issuer.Roster,
        out: File,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        known: Map<String, String>? = null,
        progress: (done: Int, total: Int) -> Unit = { _, _ -> },
    ): List<IssuedFile> {
        val kept = known ?: readPasswords(File(out, PASSWORDS_FILE))
        val passwords = roster.entries.associate { e ->
            val phone = e.phones.first()
            phone to (kept[phone] ?: Issuer.password(random))
        }
        return write(out, roster, passwords) { scratch ->
            roster.entries.mapIndexed { i, entry ->
                writeKeyFile(authority, entry, passwords.getValue(entry.phones.first()), scratch, out, random, kdf)
                    .also { progress(i + 1, roster.entries.size) }
            }
        }
    }

    /**
     * Writes the key file of [entry] alone (the other members' files are
     * not touched), with `passwords.csv` for the whole [roster]: [password]
     * for [entry], [known] for everyone else. [retired] is a file name to
     * delete in the same step (the member's previous first number).
     */
    fun issueOne(
        authority: AuthorityFile.Contents,
        roster: Issuer.Roster,
        entry: Issuer.Entry,
        password: String,
        out: File,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        known: Map<String, String>,
        retired: String? = null,
    ): IssuedFile = write(out, roster, known + (entry.phones.first() to password), retired) { scratch ->
        listOf(writeKeyFile(authority, entry, password, scratch, out, random, kdf))
    }.single()

    /** Removes a member's file and their line in `passwords.csv`. */
    fun removeOne(out: File, roster: Issuer.Roster, phone: String, known: Map<String, String>) {
        write(out, roster, known - phone, retired = fileName(phone)) { emptyList() }
    }

    private fun writeKeyFile(
        authority: AuthorityFile.Contents,
        entry: Issuer.Entry,
        password: String,
        scratch: File,
        out: File,
        random: SecureRandom,
        kdf: PasswordKdf,
    ): IssuedFile {
        val issued = Issuer.issue(authority.key, entry)
        val name = fileName(entry.phones.first())
        File(scratch, name).writeBytes(KeyFile.create(issued.identity, issued.cert, password, random, kdf))
        return IssuedFile(entry, File(out, name), password)
    }

    /**
     * Runs [files] into a scratch folder, writes `passwords.csv` for every
     * member of [roster] from [passwords] there too, and only then moves it
     * all into [out] (and deletes [retired]). A failure half-way leaves [out]
     * as it was — it used to leave a file re-sealed under a new password that
     * `passwords.csv` did not have yet.
     */
    private fun write(
        out: File,
        roster: Issuer.Roster,
        passwords: Map<String, String>,
        retired: String? = null,
        files: (scratch: File) -> List<IssuedFile>,
    ): List<IssuedFile> {
        out.mkdirs()
        val scratch = File(out, SCRATCH_DIR)
        scratch.deleteRecursively()
        scratch.mkdirs()
        try {
            val written = files(scratch)
            val lines = mutableListOf("name,phone,file,password")
            for (e in roster.entries) {
                val phone = e.phones.first()
                val password = passwords[phone] ?: continue
                lines += listOf(csv(e.name), phone, fileName(phone), password).joinToString(",")
            }
            // With a BOM, so Excel opens the Persian names as UTF-8.
            File(scratch, PASSWORDS_FILE).writeText("﻿" + lines.joinToString("\r\n") + "\r\n", Charsets.UTF_8)

            // Everything exists: now it replaces what was there.
            for (f in written) move(File(scratch, f.file.name), f.file)
            move(File(scratch, PASSWORDS_FILE), File(out, PASSWORDS_FILE))
            if (retired != null && written.none { it.file.name == retired }) File(out, retired).delete()

            // A key file of nobody on the roster any more must not stay behind,
            // ready to be handed out by mistake. Only our own <number>.hkb names.
            val current = roster.entries.map { fileName(it.phones.first()) }.toSet()
            out.listFiles { f -> f.isFile && OWN_FILE.matches(f.name) && f.name !in current }?.forEach { it.delete() }
            return written
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
    private val OWN_FILE = Regex("""0[0-9]+\.hkb""")

    /** A member's file is named by their first number: `09121234567.hkb`. */
    fun fileName(phone: String) = "$phone.hkb"

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
 * old roster kept under `backups/`, the new one written, the one member's
 * file written (or deleted), the old roster put back if that throws, and one
 * line in the log.
 */
class AuthorityFolder(val dir: File) {
    val authorityFile = File(dir, AUTHORITY_FILE)
    val rosterFile = File(dir, ROSTER_FILE)
    val issuedDir = File(dir, ISSUED_DIR)
    val passwordsFile = File(issuedDir, Issuance.PASSWORDS_FILE)

    val log = IssuanceLog(File(dir, IssuanceLog.FILE))

    class MemberError(message: String) : Exception(message)

    /**
     * Where a member's phone stands, as far as the operator recorded. Only
     * the member's own file matters: nothing anybody else is given changes
     * what their phone needs.
     */
    enum class DeliveryStatus {
        /** Holds their current key. */
        CURRENT,

        /** They were given a new key («گوشی گم شد») that has not been delivered. */
        NEW_KEY,

        /** No delivery recorded — a new member. */
        NOT_RECORDED,
    }

    /** What the folder holds now: the organization (null before the first member) and the members. */
    class Snapshot(
        val organization: String?,
        val entries: List<Issuer.Entry>,
        val passwords: Map<String, String>,
        val log: List<IssuanceLog.Entry> = emptyList(),
    ) {
        fun passwordOf(entry: Issuer.Entry): String? = passwords[entry.phones.first()]

        fun statusOf(entry: Issuer.Entry): DeliveryStatus {
            val phone = entry.phones.first()
            val delivered = log.lastOrNull { it.phone == phone && it.action == IssuanceLog.Action.DELIVERED }
                ?: return DeliveryStatus.NOT_RECORDED
            return if (delivered.generation == entry.generation) DeliveryStatus.CURRENT else DeliveryStatus.NEW_KEY
        }

        /** Members whose phone does not hold their current key. */
        val outdated: List<Issuer.Entry> get() = entries.filter { statusOf(it) != DeliveryStatus.CURRENT }
    }

    fun snapshot(): Snapshot {
        val text = if (rosterFile.isFile) rosterFile.readText(Charsets.UTF_8) else ""
        val organization = organizationOf(text)
        val roster = if (text.removePrefix("﻿").lines().any { isMemberLine(it) }) Issuer.parseRoster(text) else null
        return Snapshot(organization, roster?.entries.orEmpty(), Issuance.readPasswords(passwordsFile), log.read())
    }

    fun keyFileOf(entry: Issuer.Entry) = File(issuedDir, Issuance.fileName(entry.phones.first()))

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
     * Adds a member to `roster.csv` and writes their key file — theirs
     * only. [organization] is only used when there is no roster yet.
     */
    fun addMember(
        authority: AuthorityFile.Contents,
        name: String,
        phones: List<String>,
        random: SecureRandom,
        organization: String? = null,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
    ): Issuance.IssuedFile {
        val p = prepare(name, phones, organization)
        val entry = p.roster.entries[p.index]
        val known = Issuance.readPasswords(passwordsFile)
        return commit(p, IssuanceLog.Action.ADD, entry) {
            Issuance.issueOne(authority, p.roster, entry, Issuer.password(random), issuedDir, random, kdf, known)
        }!!
    }

    /**
     * Everything [addMember] checks, without writing anything. The panel runs
     * it before asking for confirmation, so a mistake is reported before the
     * operator has agreed to anything.
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

    /**
     * Applies [prepareEdit] and writes the member's file again (the
     * certificate names their first mobile). A member whose first number
     * changed keeps their password; their old file is deleted.
     */
    fun editMember(
        authority: AuthorityFile.Contents,
        index: Int,
        name: String,
        phones: List<String>,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
    ): Issuance.IssuedFile {
        val old = current().second.entries[index]
        val p = prepareEdit(index, name, phones)
        val entry = p.roster.entries[index]
        val known = Issuance.readPasswords(passwordsFile)
        val password = known[old.phones.first()] ?: Issuer.password(random)
        val note = if (p.keyChanged) "شمارهٔ اول ${old.phones.first()} بود؛ کلید تازه" else ""
        return commit(p, IssuanceLog.Action.EDIT, entry, note) {
            Issuance.issueOne(
                authority, p.roster, entry, password, issuedDir, random, kdf,
                known - old.phones.first(),
                retired = Issuance.fileName(old.phones.first()),
            )
        }!!
    }

    // ── A new key («گوشی گم شد») ─────────────────────────────────────────

    /** Checks giving member [index] a new key and a new password. */
    fun prepareNewKey(index: Int): Prepared {
        val (oldText, roster) = current()
        val old = roster.entries.getOrNull(index) ?: throw MemberError("این عضو دیگر در فهرست نیست.")
        val generation = maxOf(old.generation + 1, nextGeneration(old.phones.first()))
        if (generation > MemberCert.MAX_GENERATION) {
            throw MemberError("این عضو به سقف کلید تازه رسیده است؛ او را با شمارهٔ اول دیگری دوباره اضافه کنید.")
        }
        val text = replaceMemberLine(oldText, index, memberLine(old.name, old.phones, generation))
        return Prepared(oldText, text, parse(text), index, keyChanged = true)
    }

    /**
     * A new key and a NEW password for member [index] — their phone is gone,
     * and the paper with the old password may have gone with it. Nobody else
     * needs anything: a phone that has talked to this member once with the
     * new key refuses the old one from then on.
     */
    fun newKey(
        authority: AuthorityFile.Contents,
        index: Int,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
    ): Issuance.IssuedFile {
        val p = prepareNewKey(index)
        val entry = p.roster.entries[index]
        val known = Issuance.readPasswords(passwordsFile)
        return commit(p, IssuanceLog.Action.NEW_KEY, entry) {
            Issuance.issueOne(authority, p.roster, entry, Issuer.password(random), issuedDir, random, kdf, known)
        }!!
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
     * Removes member [index] from the roster; their file and password are gone
     * from `issued/`. Nothing is revoked (owner's decision): a certificate
     * already on a phone stays valid.
     */
    fun removeMember(index: Int) {
        val removed = current().second.entries[index]
        val p = prepareRemove(index)
        commit(p, IssuanceLog.Action.REMOVE, removed) {
            Issuance.removeOne(issuedDir, p.roster, removed.phones.first(), Issuance.readPasswords(passwordsFile))
            null
        }
    }

    // ── Deliveries ───────────────────────────────────────────────────────

    /** Records that member [index] was handed their current key file. */
    fun markDelivered(index: Int) = markDelivered(listOf(index))

    /** Records that each of [indices] was handed their current key file. */
    fun markDelivered(indices: List<Int>) {
        val s = snapshot()
        log.append(indices.mapNotNull { s.entries.getOrNull(it) }.map {
            logEntry(IssuanceLog.Action.DELIVERED, it, s.entries.size)
        })
    }

    // ── Internals ────────────────────────────────────────────────────────

    private fun current(): Pair<String, Issuer.Roster> {
        val text = if (rosterFile.isFile) rosterFile.readText(Charsets.UTF_8) else ""
        if (!text.removePrefix("﻿").lines().any { isMemberLine(it) }) throw MemberError("سازمان هنوز عضوی ندارد.")
        return text to parse(text)
    }

    /**
     * Backs the old roster up, writes the new one, runs [files] (the one
     * member's file, or its removal), puts the old roster back if that
     * throws, and logs one line.
     */
    private fun commit(
        p: Prepared,
        action: IssuanceLog.Action,
        entry: Issuer.Entry,
        note: String = "",
        files: () -> Issuance.IssuedFile?,
    ): Issuance.IssuedFile? {
        if (p.oldText != null) {
            val backups = File(dir, BACKUP_DIR).apply { mkdirs() }
            File(backups, "roster-${LocalDateTime.now().format(STAMP)}.csv").writeText(p.oldText, Charsets.UTF_8)
        }
        rosterFile.writeText(p.text, Charsets.UTF_8)
        val issued = try {
            files()
        } catch (e: Exception) {
            if (p.oldText != null) rosterFile.writeText(p.oldText, Charsets.UTF_8) else rosterFile.delete()
            throw e
        }
        // The file is issued; a log that cannot be written must not make the
        // operator think it was not.
        runCatching { log.append(listOf(logEntry(action, entry, p.roster.entries.size, note))) }
        return issued
    }

    private fun logEntry(
        action: IssuanceLog.Action,
        entry: Issuer.Entry,
        members: Int,
        note: String = "",
    ) = IssuanceLog.Entry(
        LocalDateTime.now().withNano(0), action, entry.name, entry.phones.first(), entry.generation, members, note,
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
        if (numbers.size > Issuer.MAX_PHONES) throw MemberError("حداکثر ${Issuer.MAX_PHONES} شماره برای هر عضو.")
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
