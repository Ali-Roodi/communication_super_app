package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * «فایل کلید» (`.hkb`): what a member imports. A [SealedFile] holding the
 * member's own identity and the [MemberCert] the authority signed for it —
 * nothing else. There is no list of colleagues in it: who else is a member
 * is learned from their certificate, the first time they answer
 * (`CertHandshake`), so no name or number of anyone else is ever on the
 * phone because of a key file.
 *
 * The secret is tied to the authority by the certificate: it is accepted
 * only when its public key is exactly the one the certificate names.
 */
object KeyFile {
    const val MAGIC = "HMRKB"
    private const val FORMAT = 1

    private fun passwordBytes(password: String) =
        Canon.keyFilePassword(password).toByteArray(Charsets.US_ASCII)

    class Opened(
        val identity: IdentityKeyPair,
        val cert: MemberCert,
        /** The anchor that signed [cert]. */
        val authority: AuthorityPublic,
    )

    fun create(
        identity: IdentityKeyPair,
        cert: MemberCert,
        password: String,
        random: SecureRandom,
        kdf: PasswordKdf = PasswordKdf.KEY_FILE,
    ): ByteArray {
        require(MessageDigest.isEqual(cert.x25519, identity.x25519Public)) {
            "the certificate is not of this identity"
        }
        val w = BinWriter()
            .u8(FORMAT)
            .bytes16(identity.serialize())
            .bytes16(cert.encoded)
        return SealedFile.seal(MAGIC, w.toByteArray(), passwordBytes(password), random, kdf)
    }

    /**
     * Opens and verifies [file]: WRONG_PASSWORD, NOT_A_KEY_FILE,
     * UNTRUSTED (no anchor signed the certificate) or BAD_BUNDLE otherwise.
     */
    fun open(file: ByteArray, password: String, anchors: List<AuthorityPublic>): Opened {
        val plain = SealedFile.open(MAGIC, file, passwordBytes(password))
        val r = BinReader(plain, SmsCryptoException.Code.BAD_BUNDLE)
        if (r.u8() != FORMAT) r.fail("unknown key file format")
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
        val signer = cert.verify(anchors)
            ?: cryptoError(SmsCryptoException.Code.UNTRUSTED, "certificate not signed by a trusted authority")
        if (!MessageDigest.isEqual(cert.x25519, identity.x25519Public)) {
            r.fail("certificate is not of the member key")
        }
        return Opened(identity, cert, signer)
    }
}
