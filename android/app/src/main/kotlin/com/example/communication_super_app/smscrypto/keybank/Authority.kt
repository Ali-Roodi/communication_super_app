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
import org.bouncycastle.crypto.signers.Ed25519Signer

/**
 * The key-bank authority's public key: an **ML-DSA-65** (FIPS 204) key and an
 * **Ed25519** (RFC 8032) key. Member certificates ([MemberCert]) are signed
 * with the Ed25519 half — a certificate travels inside the first SMS of every
 * conversation and an ML-DSA signature is 3309 bytes. The ML-DSA half signs
 * nothing today; it is part of the authority's identity ([authorityId] is
 * taken over both), which is what the app's trust anchor pins.
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

        private val ID_LABEL = Kdf.label("hamresan.authority.id.v1")

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

    /** A [MemberCert]'s Ed25519 signature over [body] (its own context). */
    internal fun verifyCertificate(body: ByteArray, signature: ByteArray): Boolean {
        if (signature.size != MemberCert.SIGNATURE_BYTES) return false
        return Ed25519Signer().run {
            init(false, ed25519)
            update(body, 0, body.size)
            verifySignature(signature)
        }
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

    /** Ed25519 over a [MemberCert] body, which starts with its own label. */
    internal fun signCertificate(body: ByteArray): ByteArray = Ed25519Signer().run {
        init(true, ed25519)
        update(body, 0, body.size)
        generateSignature()
    }

    /** The identity of the member keyed by [phone] (canonical) at [generation]. */
    fun memberIdentity(phone: String, generation: Int): IdentityKeyPair {
        require(generation >= 0)
        val number = Canon.phone(phone) ?: throw IllegalArgumentException("not a phone number: $phone")
        val info = BinWriter().text(number).u32(generation.toLong()).toByteArray()
        return IdentityKeyPair.fromSeed(Kdf.hkdf(memberSeed, MEMBER_SALT, info, IdentityKeyPair.SEED_BYTES))
    }
}
