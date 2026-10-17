package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
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
    /** 2 added the member's certificate ([MemberCert]); 1 is still read. */
    private const val FORMAT = 2
    private const val FORMAT_WITHOUT_CERT = 1

    private fun passwordBytes(password: String) =
        Canon.keyFilePassword(password).toByteArray(Charsets.US_ASCII)

    class Opened(
        val signed: SignedDirectory,
        val directory: Directory,
        /** Which member this file was issued to; null for a directory-only file. */
        val memberIndex: Int?,
        val identity: IdentityKeyPair?,
        /** The member's certificate — null for a directory-only file, a member
         *  with no mobile number, or a file from before certificates. */
        val cert: MemberCert? = null,
    )

    fun create(
        signed: SignedDirectory,
        member: Pair<Int, IdentityKeyPair>?,
        password: String,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        cert: MemberCert? = null,
    ): ByteArray {
        val w = BinWriter().u8(FORMAT).bytes32(signed.encode())
        if (member == null) {
            w.u8(0)
        } else {
            w.u8(1).u16(member.first).bytes16(member.second.serialize())
        }
        if (cert == null) w.u8(0) else w.u8(1).bytes16(cert.encoded)
        return SealedFile.seal(MAGIC, w.toByteArray(), passwordBytes(password), random, kdf)
    }

    /**
     * Opens and verifies [file]: WRONG_PASSWORD, NOT_A_KEY_FILE, UNTRUSTED,
     * BAD_SIGNATURE or BAD_BUNDLE otherwise.
     */
    fun open(file: ByteArray, password: String, anchors: List<AuthorityPublic>): Opened {
        val plain = SealedFile.open(MAGIC, file, passwordBytes(password))
        val r = BinReader(plain, SmsCryptoException.Code.BAD_BUNDLE)
        val format = r.u8()
        if (format != FORMAT && format != FORMAT_WITHOUT_CERT) r.fail("unknown key file format")
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
        val certBytes = if (format == FORMAT) {
            when (r.u8()) {
                0 -> null
                1 -> r.bytes16()
                else -> r.fail("bad certificate flag")
            }
        } else {
            null
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
        val cert = certBytes?.let { bytes ->
            val owner = member ?: r.fail("a certificate without a member key")
            val identity = owner.second
            val cert = try {
                MemberCert.parse(bytes)
            } catch (e: SmsCryptoException) {
                r.fail("invalid certificate")
            }
            val signer = cert.verify(anchors)
                ?: cryptoError(SmsCryptoException.Code.BAD_SIGNATURE, "certificate signature does not verify")
            if (!signer.authorityId.contentEquals(directory.authorityId)) {
                r.fail("certificate of another authority")
            }
            if (!cert.x25519.contentEquals(identity.public.x25519.encoded)) {
                r.fail("certificate is not of the member key")
            }
            if (cert.phone !in directory.members[owner.first].phones) {
                r.fail("certificate names a number the member does not have")
            }
            cert
        }
        return Opened(signed, directory, member?.first, member?.second, cert)
    }
}
