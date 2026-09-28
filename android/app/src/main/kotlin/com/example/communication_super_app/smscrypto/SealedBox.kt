package com.example.communication_super_app.smscrypto

import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.kems.MLKEMExtractor
import org.bouncycastle.crypto.kems.MLKEMGenerator
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

/**
 * One-way sealing to a [PublicIdentity]: anyone holding the public half can
 * seal, only the holder of the key pair can open.
 *
 * This is how Kotlin writes down something secret while the secure section
 * is locked (a call to a hidden contact, an SMS from one): it seals the record
 * to the section's own public key and parks the blob in the main database.
 * Kotlin can never read it back; the section opens it the next time it is
 * unlocked. Hybrid like the handshake — ML-KEM-768 and an ephemeral X25519
 * both feed the key — so a record stays secret unless both are broken.
 *
 * ```
 * blob = FORMAT ‖ eph (32) ‖ ML-KEM ciphertext (1088) ‖ AES-256-GCM(record)
 * key, nonce = HKDF(ssKem ‖ X25519(eph, X), salt = SHA-256(label ‖ recipient ‖ header))
 * ```
 *
 * The format is pinned by `SealedBoxTest` — a change is a new [FORMAT].
 */
object SealedBox {
    private const val FORMAT: Byte = 1
    private const val EPHEMERAL_BYTES = 32
    private const val KEM_CIPHERTEXT_BYTES = 1088
    private const val KEY_BYTES = 32
    private const val NONCE_BYTES = 12
    private const val TAG_BYTES = 16
    private const val HEADER_BYTES = 1 + EPHEMERAL_BYTES + KEM_CIPHERTEXT_BYTES

    /** The fixed cost of sealing: what a blob adds to its record. */
    const val OVERHEAD = HEADER_BYTES + TAG_BYTES

    private val SALT_LABEL = Kdf.label("hamresan.sealed-box.salt.v1")
    private val KEY_INFO = Kdf.label("hamresan.sealed-box.key.v1")

    fun seal(recipient: PublicIdentity, record: ByteArray, random: SecureRandom): ByteArray {
        val ephemeral = X25519PrivateKeyParameters(random)
        val kem = MLKEMGenerator(random).generateEncapsulated(recipient.mlkem)
        val header = byteArrayOf(FORMAT) + ephemeral.generatePublicKey().encoded + kem.encapsulation
        check(header.size == HEADER_BYTES) { "unexpected header size ${header.size}" }
        val dh = agree(ephemeral, recipient.x25519.encoded)
        val cipher = cipher(Cipher.ENCRYPT_MODE, recipient, header, kem.secret, dh)
        return header + cipher.doFinal(record)
    }

    fun open(own: IdentityKeyPair, blob: ByteArray): ByteArray {
        if (blob.size < OVERHEAD || blob[0] != FORMAT) {
            cryptoError(SmsCryptoException.Code.BAD_PAYLOAD, "not a sealed record")
        }
        val header = blob.copyOfRange(0, HEADER_BYTES)
        val ephemeral = blob.copyOfRange(1, 1 + EPHEMERAL_BYTES)
        val ciphertext = blob.copyOfRange(1 + EPHEMERAL_BYTES, HEADER_BYTES)
        val ssKem = MLKEMExtractor(own.mlkem).extractSecret(ciphertext)
        val dh = agree(own.x25519, ephemeral)
        val cipher = cipher(Cipher.DECRYPT_MODE, own.public, header, ssKem, dh)
        return try {
            cipher.doFinal(blob, HEADER_BYTES, blob.size - HEADER_BYTES)
        } catch (e: AEADBadTagException) {
            // Another key, or an altered blob (ML-KEM's implicit rejection
            // turns a wrong key into a random secret, which lands here too).
            cryptoError(SmsCryptoException.Code.AUTH_FAILED, "sealed record does not open")
        }
    }

    private fun cipher(
        mode: Int,
        recipient: PublicIdentity,
        header: ByteArray,
        ssKem: ByteArray,
        dh: ByteArray,
    ): Cipher {
        val salt = Kdf.sha256(SALT_LABEL, recipient.encoded, header)
        val okm = Kdf.hkdf(ssKem + dh, salt, KEY_INFO, KEY_BYTES + NONCE_BYTES)
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(
                mode,
                SecretKeySpec(okm, 0, KEY_BYTES, "AES"),
                GCMParameterSpec(TAG_BYTES * 8, okm, KEY_BYTES, NONCE_BYTES),
            )
            updateAAD(header)
        }
    }

    /** X25519, refusing the all-zero result of a small-order point (RFC 7748 §6.1). */
    private fun agree(secret: X25519PrivateKeyParameters, other: ByteArray): ByteArray {
        val out = ByteArray(X25519PrivateKeyParameters.SECRET_SIZE)
        try {
            secret.generateSecret(X25519PublicKeyParameters(other, 0), out, 0)
        } catch (e: IllegalStateException) {
            cryptoError(SmsCryptoException.Code.BAD_KEY, "invalid X25519 key")
        }
        return out
    }
}
