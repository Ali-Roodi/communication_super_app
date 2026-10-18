package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * «فایل کلید» (`.hkb`): what a member imports. A [SealedFile] holding the
 * signed [Directory], the member's own identity and the member's
 * [MemberCert] — every key file has all three.
 *
 * The member's secret is **not** signed separately: it is accepted only when
 * its public key is exactly the one the signed directory lists for that
 * member, which ties it to the authority's signature just as well. The
 * certificate is signed by the same authority and must name that same key.
 */
object KeyFile {
    const val MAGIC = "HMRKB"
    private const val FORMAT = 2

    private fun passwordBytes(password: String) =
        Canon.keyFilePassword(password).toByteArray(Charsets.US_ASCII)

    class Opened(
        val signed: SignedDirectory,
        val directory: Directory,
        /** Which member this file was issued to. */
        val memberIndex: Int,
        val identity: IdentityKeyPair,
        val cert: MemberCert,
    )

    fun create(
        signed: SignedDirectory,
        member: Pair<Int, IdentityKeyPair>,
        password: String,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
        cert: MemberCert,
    ): ByteArray {
        val w = BinWriter()
            .u8(FORMAT)
            .bytes32(signed.encode())
            .u16(member.first)
            .bytes16(member.second.serialize())
            .bytes16(cert.encoded)
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
        val index = r.u16()
        val identity = try {
            IdentityKeyPair.parse(r.bytes16())
        } catch (e: SmsCryptoException) {
            r.fail("invalid member key")
        }
        val cert = try {
            MemberCert.parse(r.bytes16())
        } catch (e: SmsCryptoException) {
            r.fail("invalid certificate")
        }
        r.end()
        val directory = signed.verify(anchors)
        val listed = directory.members.getOrNull(index) ?: r.fail("member index out of range")
        if (!MessageDigest.isEqual(listed.x25519, identity.x25519Public)) {
            r.fail("member key does not match the directory")
        }
        val signer = cert.verify(anchors)
            ?: cryptoError(SmsCryptoException.Code.BAD_SIGNATURE, "certificate signature does not verify")
        if (!signer.authorityId.contentEquals(directory.authorityId)) {
            r.fail("certificate of another authority")
        }
        if (!MessageDigest.isEqual(cert.x25519, identity.x25519Public)) {
            r.fail("certificate is not of the member key")
        }
        if (cert.phone !in listed.phones) {
            r.fail("certificate names a number the member does not have")
        }
        return Opened(signed, directory, index, identity, cert)
    }
}
