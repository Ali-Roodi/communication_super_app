package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.SmsCryptoException
import java.security.SecureRandom

/**
 * «فایل کلید» (`.hkb`): what a member imports. A [SealedFile] holding the
 * signed [Directory] and, usually, the member's own identity.
 *
 * The member's secret is **not** signed separately: it is accepted only when
 * its public half is exactly the key the signed directory lists for that
 * member, which ties it to the authority's signature just as well.
 */
object KeyFile {
    const val MAGIC = "HMRKB"
    private const val FORMAT = 1

    private fun passwordBytes(password: String) =
        Canon.keyFilePassword(password).toByteArray(Charsets.US_ASCII)

    class Opened(
        val signed: SignedDirectory,
        val directory: Directory,
        /** Which member this file was issued to; null for a directory-only file. */
        val memberIndex: Int?,
        val identity: IdentityKeyPair?,
    )

    fun create(
        signed: SignedDirectory,
        member: Pair<Int, IdentityKeyPair>?,
        password: String,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
    ): ByteArray {
        val w = BinWriter().u8(FORMAT).bytes32(signed.encode())
        if (member == null) {
            w.u8(0)
        } else {
            w.u8(1).u16(member.first).bytes16(member.second.serialize())
        }
        return SealedFile.seal(MAGIC, w.toByteArray(), passwordBytes(password), random, kdf)
    }

    /**
     * Opens and verifies [file]: WRONG_PASSWORD, NOT_A_KEY_FILE, UNTRUSTED,
     * BAD_SIGNATURE or BAD_BUNDLE otherwise.
     */
    fun open(file: ByteArray, password: String, anchors: List<AuthorityPublic>): Opened {
        val plain = SealedFile.open(MAGIC, file, passwordBytes(password))
        val r = BinReader(plain, SmsCryptoException.Code.BAD_BUNDLE)
        if (r.u8() != FORMAT) r.fail("unknown key file format")
        val signed = SignedDirectory.decode(r.bytes32())
        val hasMember = r.u8()
        val member = when (hasMember) {
            0 -> null
            1 -> {
                val index = r.u16()
                val identity = try {
                    IdentityKeyPair.parse(r.bytes16())
                } catch (e: SmsCryptoException) {
                    r.fail("invalid member key")
                }
                index to identity
            }
            else -> r.fail("bad member flag")
        }
        r.end()
        val directory = signed.verify(anchors)
        if (member != null) {
            val listed = directory.members.getOrNull(member.first)
                ?: r.fail("member index out of range")
            if (!listed.identity.encoded.contentEquals(member.second.public.encoded)) {
                r.fail("member key does not match the directory")
            }
        }
        return Opened(signed, directory, member?.first, member?.second)
    }
}
