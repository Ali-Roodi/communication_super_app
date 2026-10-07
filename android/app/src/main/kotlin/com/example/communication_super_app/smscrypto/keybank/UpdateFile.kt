package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.Kdf
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * «فایل به‌روزرسانی» (`update.hku`): an organization's newest signed
 * directory and nothing else — no member's key — so one file serves every
 * member and nobody types a password.
 *
 * Every issue writes one next to the members' key files, from the SAME
 * signed directory (same serial), so importing it and then the member's own
 * file never meets a "newer" copy that refuses the other.
 *
 * It is sealed rather than plain: the directory lists every member's name
 * and numbers. The sealing password is derived from the directory id, which
 * only a phone that already holds a key file of this organization has (and
 * the issuing tool). The id is 64 random bits behind Argon2id: out of reach
 * for anyone else, while a member's phone opens it without asking anything.
 * A former member still holds the id — they knew the roster anyway.
 *
 * Authenticity does not come from the sealing: the directory inside is
 * verified against the trusted authority exactly as in a key file.
 */
object UpdateFile {
    const val MAGIC = "HMRKU"
    private const val FORMAT = 1
    private val LABEL = Kdf.label("hamresan update file v1|")

    private fun password(directoryId: ByteArray) = LABEL + directoryId

    fun create(
        signed: SignedDirectory,
        directoryId: ByteArray,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
    ): ByteArray {
        val plain = BinWriter().u8(FORMAT).bytes32(signed.encode()).toByteArray()
        return SealedFile.seal(MAGIC, plain, password(directoryId), random, kdf)
    }

    /** Whether [file] is an update file (by its clear header), before any work. */
    fun looksLike(file: ByteArray): Boolean {
        val magic = Kdf.label(MAGIC)
        return file.size > magic.size && file.copyOf(magic.size).contentEquals(magic)
    }

    /**
     * Opens [file] with the first of [directoryIds] (the directories this
     * phone holds) that seals it, and verifies it against [anchors].
     * WRONG_PASSWORD when it belongs to none of them; NOT_A_KEY_FILE,
     * UNTRUSTED, BAD_SIGNATURE or BAD_BUNDLE as for a key file.
     */
    fun open(file: ByteArray, directoryIds: List<ByteArray>, anchors: List<AuthorityPublic>): KeyFile.Opened {
        for (id in directoryIds) {
            val plain = try {
                SealedFile.open(MAGIC, file, password(id))
            } catch (e: SmsCryptoException) {
                if (e.code == SmsCryptoException.Code.WRONG_PASSWORD) continue
                throw e
            }
            val r = BinReader(plain, SmsCryptoException.Code.BAD_BUNDLE)
            if (r.u8() != FORMAT) r.fail("unknown update file format")
            val signed = SignedDirectory.decode(r.bytes32())
            r.end()
            val directory = signed.verify(anchors)
            // Sealed for one directory, carrying another: not ours to trust.
            if (!MessageDigest.isEqual(directory.directoryId, id)) r.fail("update file names another directory")
            return KeyFile.Opened(signed, directory, null, null)
        }
        // Also when the phone holds no directory at all: the header said
        // update file, so whether it is one is not in doubt — only whose.
        if (!looksLike(file)) cryptoError(SmsCryptoException.Code.NOT_A_KEY_FILE, "not an update file")
        cryptoError(SmsCryptoException.Code.WRONG_PASSWORD, "not for a directory this phone holds")
    }
}
