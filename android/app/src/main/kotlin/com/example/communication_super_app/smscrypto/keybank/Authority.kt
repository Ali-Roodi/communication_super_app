package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.Kdf
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
import java.security.SecureRandom
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.MLDSAParameters
import org.bouncycastle.crypto.params.MLDSAPrivateKeyParameters
import org.bouncycastle.crypto.params.MLDSAPublicKeyParameters
import org.bouncycastle.crypto.params.ParametersWithContext
import org.bouncycastle.crypto.params.ParametersWithRandom
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.bouncycastle.crypto.signers.MLDSASigner

/**
 * The key-bank authority's public key — **ML-DSA-65** (FIPS 204) plus
 * **Ed25519** (RFC 8032). A directory is accepted only when *both* signatures
 * verify, so a forgery needs both schemes broken.
 *
 * This is the one thing the app hardcodes (its trust anchor). It is not a
 * secret: knowing it lets one *check* a signature, never make one.
 */
class AuthorityPublic internal constructor(
    internal val mldsa: MLDSAPublicKeyParameters,
    internal val ed25519: Ed25519PublicKeyParameters,
) {
    companion object {
        private const val FORMAT: Byte = 1
        const val MLDSA_BYTES = 1952
        const val ED25519_BYTES = 32
        const val ENCODED_BYTES = 1 + MLDSA_BYTES + ED25519_BYTES
        const val ID_BYTES = 8

        internal const val SIGNATURE_BYTES = 1 + 64 + 3309
        private val ID_LABEL = Kdf.label("hamresan.authority.id.v1")

        /** ML-DSA's context string and Ed25519's message prefix. */
        internal val CONTEXT = Kdf.label("hamresan.directory.v1")

        fun parse(bytes: ByteArray): AuthorityPublic {
            if (bytes.size != ENCODED_BYTES || bytes[0] != FORMAT) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "not an authority key")
            }
            return AuthorityPublic(
                MLDSAPublicKeyParameters(MLDSAParameters.ml_dsa_65, bytes.copyOfRange(1, 1 + MLDSA_BYTES)),
                Ed25519PublicKeyParameters(bytes, 1 + MLDSA_BYTES),
            )
        }
    }

    val encoded: ByteArray by lazy { byteArrayOf(FORMAT) + mldsa.encoded + ed25519.encoded }

    val authorityId: ByteArray by lazy { Kdf.sha256(ID_LABEL, encoded).copyOf(ID_BYTES) }

    /** True only when both halves of [signature] verify over [message]. */
    fun verify(message: ByteArray, signature: ByteArray): Boolean {
        if (signature.size != SIGNATURE_BYTES || signature[0] != FORMAT) return false
        val edOk = Ed25519Signer().run {
            init(false, ed25519)
            update(CONTEXT, 0, CONTEXT.size)
            update(message, 0, message.size)
            verifySignature(signature.copyOfRange(1, 65))
        }
        val mldsaOk = MLDSASigner().run {
            init(false, ParametersWithContext(mldsa, CONTEXT))
            update(message, 0, message.size)
            verifySignature(signature.copyOfRange(65, SIGNATURE_BYTES))
        }
        return edOk and mldsaOk
    }
}

/**
 * The authority's private side — only ever in the Windows tool, never in the
 * app. Three seeds: ML-DSA, Ed25519, and the **member seed** every member's
 * identity is derived from.
 *
 * Deriving members (rather than generating and storing each key) is what lets
 * the tool re-issue a member's key file at any time without keeping private
 * keys around: it only needs the authority file and the roster. A member
 * whose phone was lost gets a new `generation`, and so a new key.
 */
class AuthorityKey private constructor(
    private val mldsaSeed: ByteArray,
    private val ed25519Seed: ByteArray,
    private val memberSeed: ByteArray,
) {
    companion object {
        private const val FORMAT: Byte = 1
        private const val SEED_BYTES = 32
        const val SERIALIZED_BYTES = 1 + 3 * SEED_BYTES
        private val MEMBER_SALT = Kdf.label("hamresan.authority.member.v1")

        fun generate(random: SecureRandom): AuthorityKey = AuthorityKey(
            ByteArray(SEED_BYTES).also(random::nextBytes),
            ByteArray(SEED_BYTES).also(random::nextBytes),
            ByteArray(SEED_BYTES).also(random::nextBytes),
        )

        fun parse(bytes: ByteArray): AuthorityKey {
            if (bytes.size != SERIALIZED_BYTES || bytes[0] != FORMAT) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "not an authority private key")
            }
            return AuthorityKey(
                bytes.copyOfRange(1, 1 + SEED_BYTES),
                bytes.copyOfRange(1 + SEED_BYTES, 1 + 2 * SEED_BYTES),
                bytes.copyOfRange(1 + 2 * SEED_BYTES, SERIALIZED_BYTES),
            )
        }
    }

    private val mldsa by lazy { MLDSAPrivateKeyParameters(MLDSAParameters.ml_dsa_65, mldsaSeed) }
    private val ed25519 by lazy { Ed25519PrivateKeyParameters(ed25519Seed, 0) }

    val public: AuthorityPublic by lazy {
        AuthorityPublic(mldsa.publicKeyParameters, ed25519.generatePublicKey())
    }

    fun serialize(): ByteArray = byteArrayOf(FORMAT) + mldsaSeed + ed25519Seed + memberSeed

    fun sign(message: ByteArray, random: SecureRandom): ByteArray {
        val ed = Ed25519Signer().run {
            init(true, ed25519)
            update(AuthorityPublic.CONTEXT, 0, AuthorityPublic.CONTEXT.size)
            update(message, 0, message.size)
            generateSignature()
        }
        val ml = MLDSASigner().run {
            init(true, ParametersWithContext(ParametersWithRandom(mldsa, random), AuthorityPublic.CONTEXT))
            update(message, 0, message.size)
            generateSignature()
        }
        return byteArrayOf(1) + ed + ml
    }

    /** The identity of the member keyed by [phone] (canonical) at [generation]. */
    fun memberIdentity(phone: String, generation: Int): IdentityKeyPair {
        require(generation >= 0)
        val number = Canon.phone(phone) ?: throw IllegalArgumentException("not a phone number: $phone")
        val info = BinWriter().text(number).u32(generation.toLong()).toByteArray()
        return IdentityKeyPair.fromSeed(Kdf.hkdf(memberSeed, MEMBER_SALT, info, IdentityKeyPair.SEED_BYTES))
    }
}
