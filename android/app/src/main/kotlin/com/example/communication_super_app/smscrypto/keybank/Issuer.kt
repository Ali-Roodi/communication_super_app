package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import java.security.SecureRandom
import java.text.Normalizer

/**
 * The authority's side of the key bank: what the Windows tool
 * (`tools/keybank/`) runs. It lives here, next to what the app runs, so the
 * two are compiled from the same source and tested together — a key file the
 * tool writes is by construction one the app reads. R8 drops all of it from
 * the APK: nothing in the app calls it.
 */
object Issuer {
    /** One roster line: a member, their numbers, and their key generation. */
    class Entry(val name: String, val phones: List<String>, val generation: Int)

    /** A roster file: the organization's name and its members. */
    class Roster(val organization: String, val entries: List<Entry>)

    class Issued(
        val signed: SignedDirectory,
        val directory: Directory,
        val identities: List<IdentityKeyPair>,
    )

    class RosterException(message: String) : Exception(message)

    /**
     * One `organization,<name>` line (`سازمان,<name>` too), then
     * `name,phones,generation` per member — phones separated by `;` or
     * spaces, generation optional (0). UTF-8 with or without BOM, commas or
     * tabs, `#` comments and a `name,phones` header line are all accepted.
     *
     * The organization's name is in the file, not on the command line, on
     * purpose: Java on Windows reads its arguments in the ANSI code page and
     * a Persian name arrives as question marks.
     */
    fun parseRoster(text: String): Roster {
        var organization: String? = null
        val entries = ArrayList<Entry>()
        val seen = HashMap<String, Int>()
        text.removePrefix("\uFEFF").lines().forEachIndexed { i, raw ->
            val line = raw.trim()
            val lineNo = i + 1
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            val fields = line.split(if ('\t' in line) '\t' else ',').map { it.trim() }
            if (fields[0].lowercase() in setOf("organization", "سازمان")) {
                if (organization != null) throw RosterException("line $lineNo: a second organization line")
                organization = fields.drop(1).joinToString(",").trim().ifEmpty {
                    throw RosterException("line $lineNo: the organization has no name")
                }
                return@forEachIndexed
            }
            if (fields[0].lowercase() in setOf("name", "نام")) return@forEachIndexed
            if (fields.size !in 2..3 || fields[0].isEmpty()) {
                throw RosterException("line $lineNo: expected name,phones[,generation]")
            }
            val phones = fields[1].split(';', ' ').filter { it.isNotBlank() }.map { p ->
                Canon.phone(p) ?: throw RosterException("line $lineNo: not a phone number: $p")
            }
            if (phones.isEmpty() || phones.size > Directory.MAX_PHONES) {
                throw RosterException("line $lineNo: 1 to ${Directory.MAX_PHONES} phone numbers")
            }
            for (p in phones) {
                val first = seen.put(p, lineNo)
                if (first != null) throw RosterException("line $lineNo: $p is already on line $first")
            }
            val generation = fields.getOrNull(2)?.takeIf { it.isNotEmpty() }?.let {
                it.toIntOrNull()?.takeIf { g -> g >= 0 } ?: throw RosterException("line $lineNo: bad generation")
            } ?: 0
            entries += Entry(fields[0], phones, generation)
        }
        if (entries.isEmpty()) throw RosterException("the roster is empty")
        if (entries.size > Directory.MAX_MEMBERS) throw RosterException("too many members")
        return Roster(organization ?: throw RosterException("no organization line"), entries)
    }

    /**
     * Signs a directory of [roster]. A member's key is derived from their
     * first phone number and generation, so issuing again from the same
     * roster gives every member the same key.
     */
    fun issue(
        authority: AuthorityKey,
        directoryId: ByteArray,
        roster: Roster,
        serial: Long,
        random: SecureRandom,
    ): Issued {
        val identities = roster.entries.map { authority.memberIdentity(it.phones.first(), it.generation) }
        val directory = Directory(
            authority.public.authorityId,
            directoryId,
            serial,
            roster.organization,
            roster.entries.mapIndexed { i, e -> Directory.Member(e.name, e.phones, identities[i].public) },
        )
        return Issued(SignedDirectory.sign(directory, authority, random), directory, identities)
    }

    private const val ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

    /** 20 characters of an unambiguous 32-letter alphabet (100 bits), in groups of four. */
    fun password(random: SecureRandom): String =
        (0 until 20).joinToString("") { i ->
            (if (i > 0 && i % 4 == 0) "-" else "") + ALPHABET[random.nextInt(ALPHABET.length)]
        }
}

/**
 * The Windows tool's own file (`.hka`): the authority key and the directory
 * id, sealed under a password the operator chooses.
 * Whoever holds this file and its password can issue keys for the whole
 * organization — it belongs offline, with a backup.
 */
object AuthorityFile {
    const val MAGIC = "HMRKA"
    private const val FORMAT = 1
    const val MIN_PASSWORD_LENGTH = 12

    class Contents(val key: AuthorityKey, val directoryId: ByteArray)

    /** The operator's password as typed, only NFKC-normalized. */
    private fun passwordBytes(password: String) =
        Normalizer.normalize(password, Normalizer.Form.NFKC).toByteArray(Charsets.UTF_8)

    fun create(
        contents: Contents,
        password: String,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
    ): ByteArray {
        require(password.length >= MIN_PASSWORD_LENGTH) { "password too short" }
        val plain = BinWriter()
            .u8(FORMAT)
            .bytes16(contents.key.serialize())
            .raw(contents.directoryId)
            .toByteArray()
        return SealedFile.seal(MAGIC, plain, passwordBytes(password), random, kdf)
    }

    fun open(file: ByteArray, password: String): Contents {
        val r = BinReader(
            SealedFile.open(MAGIC, file, passwordBytes(password)),
            com.example.communication_super_app.smscrypto.SmsCryptoException.Code.BAD_BUNDLE,
        )
        if (r.u8() != FORMAT) r.fail("unknown authority file format")
        val key = AuthorityKey.parse(r.bytes16())
        val directoryId = r.raw(Directory.ID_BYTES)
        r.end()
        return Contents(key, directoryId)
    }
}
