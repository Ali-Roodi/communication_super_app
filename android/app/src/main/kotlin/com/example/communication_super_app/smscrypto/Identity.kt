package com.example.communication_super_app.smscrypto

import java.security.SecureRandom
import org.bouncycastle.crypto.params.MLKEMParameters
import org.bouncycastle.crypto.params.MLKEMPrivateKeyParameters
import org.bouncycastle.crypto.params.MLKEMPublicKeyParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

/**
 * A member's long-term key pair: **ML-KEM-768** (FIPS 203, the post-quantum
 * half) plus **X25519** (RFC 7748, the classical half). Both halves take part
 * in every session, so a session stays secret unless *both* are broken.
 *
 * Stored as seeds, not expanded keys — 64 bytes of ML-KEM seed (`d || z`) and
 * the 32-byte X25519 scalar — so the secret is 97 bytes serialized. It is
 * only ever handed to this layer from the secure section; it is never written
 * anywhere by Kotlin.
 */
class IdentityKeyPair private constructor(
    private val mlkemSeed: ByteArray,
    private val x25519Scalar: ByteArray,
) {
    companion object {
        private const val FORMAT: Byte = 1
        const val SEED_BYTES = 32
        private const val MLKEM_SEED_BYTES = 64
        private const val X25519_BYTES = 32
        const val SERIALIZED_BYTES = 1 + MLKEM_SEED_BYTES + X25519_BYTES

        private val SEED_SALT = Kdf.label("hamresan.sms.identity.v1")

        /**
         * The deterministic key pair of a 32-byte [seed]. This is how a key
         * bank entry that is a *seed* (a passphrase run through a KDF, or a
         * seed the authority issued) becomes a key pair: the same seed yields
         * the same keys on every phone and in every edition.
         */
        fun fromSeed(seed: ByteArray): IdentityKeyPair {
            if (seed.size != SEED_BYTES) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "seed must be $SEED_BYTES bytes")
            }
            return IdentityKeyPair(
                Kdf.hkdf(seed, SEED_SALT, "mlkem768 d||z", MLKEM_SEED_BYTES),
                Kdf.hkdf(seed, SEED_SALT, "x25519", X25519_BYTES),
            )
        }

        fun generate(random: SecureRandom): IdentityKeyPair =
            fromSeed(ByteArray(SEED_BYTES).also(random::nextBytes))

        fun parse(bytes: ByteArray): IdentityKeyPair {
            if (bytes.size != SERIALIZED_BYTES || bytes[0] != FORMAT) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "not an identity key pair")
            }
            return IdentityKeyPair(
                bytes.copyOfRange(1, 1 + MLKEM_SEED_BYTES),
                bytes.copyOfRange(1 + MLKEM_SEED_BYTES, SERIALIZED_BYTES),
            )
        }
    }

    internal val mlkem: MLKEMPrivateKeyParameters by lazy {
        MLKEMPrivateKeyParameters(MLKEMParameters.ml_kem_768, mlkemSeed)
    }

    internal val x25519: X25519PrivateKeyParameters by lazy {
        X25519PrivateKeyParameters(x25519Scalar)
    }

    val public: PublicIdentity by lazy {
        PublicIdentity(
            MLKEMPublicKeyParameters(MLKEMParameters.ml_kem_768, mlkem.publicKey),
            x25519.generatePublicKey(),
        )
    }

    fun serialize(): ByteArray = byteArrayOf(FORMAT) + mlkemSeed + x25519Scalar
}

/**
 * What a member publishes: the ML-KEM-768 encapsulation key (1184 bytes) and
 * the X25519 public key (32). Its [keyId] — 8 bytes of a hash over both — is
 * how packets name a sender and a recipient.
 */
class PublicIdentity internal constructor(
    internal val mlkem: MLKEMPublicKeyParameters,
    internal val x25519: X25519PublicKeyParameters,
) {
    companion object {
        private const val FORMAT: Byte = 1
        const val MLKEM_BYTES = 1184
        const val X25519_BYTES = 32
        const val ENCODED_BYTES = 1 + MLKEM_BYTES + X25519_BYTES
        const val KEY_ID_BYTES = 8

        private val KEY_ID_LABEL = Kdf.label("hamresan.sms.key-id.v1")

        /**
         * Parses and **validates** a published identity. The ML-KEM key must
         * pass FIPS 203's modulus check (§7.2) — a key that fails it is
         * refused here, before anything is encapsulated to it.
         */
        fun parse(bytes: ByteArray): PublicIdentity {
            if (bytes.size != ENCODED_BYTES || bytes[0] != FORMAT) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "not a public identity")
            }
            val mlkem = try {
                MLKEMPublicKeyParameters(
                    MLKEMParameters.ml_kem_768,
                    bytes.copyOfRange(1, 1 + MLKEM_BYTES),
                )
            } catch (e: IllegalArgumentException) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "invalid ML-KEM key")
            }
            return PublicIdentity(
                mlkem,
                X25519PublicKeyParameters(bytes, 1 + MLKEM_BYTES),
            )
        }
    }

    val encoded: ByteArray by lazy {
        byteArrayOf(FORMAT) + mlkem.encoded + x25519.encoded
    }

    val keyId: ByteArray by lazy {
        Kdf.sha256(KEY_ID_LABEL, encoded).copyOf(KEY_ID_BYTES)
    }
}
