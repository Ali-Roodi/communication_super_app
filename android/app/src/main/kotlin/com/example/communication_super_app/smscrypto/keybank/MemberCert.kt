package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.Kdf
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError

/**
 * «گواهی عضو»: the authority's statement that [x25519] is the key of the
 * member reachable at [phone] — small enough to travel inside a session
 * request (`CertHandshake`), so two members who have never been given each
 * other's keys can still talk. That is the whole point of it: adding a member
 * means issuing **their** file, and nobody else's phone needs anything new.
 *
 * ```
 * format(1) ‖ phone(5, packed BCD of the 10 digits after the leading 0)
 *           ‖ generation(1) ‖ x25519(32) ‖ Ed25519 signature(64)      = 103
 * ```
 *
 * The signature is Ed25519 only: an ML-DSA signature is 3309 bytes, thirty
 * SMS parts on every first contact.
 * The classical one was chosen (1405/07/25); what it authenticates is a
 * handshake happening *now*, which a future quantum computer cannot reach
 * back into. The confidentiality of what follows is made post-quantum by the
 * session's upgrade (`Upgrade`). The authority's id is signed but not sent —
 * the verifier puts in the id of each anchor it tries.
 *
 * [generation] is the roster's: «گوشی گم شد» in the issuance panel raises it,
 * and a phone that has seen a member's generation *n* refuses a certificate
 * below it. There is no expiry and no revocation list — design decision.
 *
 * Only Iranian mobile numbers (`09` + 9 digits) get one: a landline cannot
 * receive the SMS the handshake is made of.
 */
class MemberCert private constructor(
    val phone: String,
    val generation: Int,
    val x25519: ByteArray,
    val signature: ByteArray,
) {
    companion object {
        private const val FORMAT: Byte = 1
        private const val PHONE_BYTES = 5
        const val X25519_BYTES = 32
        const val SIGNATURE_BYTES = 64
        const val ENCODED_BYTES = 1 + PHONE_BYTES + 1 + X25519_BYTES + SIGNATURE_BYTES
        const val KEY_ID_BYTES = 8
        const val MAX_GENERATION = 255

        private val SIGNED_LABEL = Kdf.label("hamresan.member-cert.v1")
        private val KEY_ID_LABEL = Kdf.label("hamresan.sms.cert-key-id.v1")
        private val MOBILE = Regex("^09[0-9]{9}$")

        /** Whether [phone] (canonical) is a number a certificate can name. */
        fun canName(phone: String): Boolean = MOBILE.matches(phone)

        /** The authority signs [identity]'s X25519 key as [phone]'s. */
        fun issue(
            authority: AuthorityKey,
            phone: String,
            generation: Int,
            identity: IdentityKeyPair,
        ): MemberCert {
            require(canName(phone)) { "a certificate names a mobile number (09…)" }
            require(generation in 0..MAX_GENERATION) { "generation 0..$MAX_GENERATION" }
            val x25519 = identity.public.x25519.encoded
            val body = signedBody(authority.public.authorityId, phone, generation, x25519)
            return MemberCert(phone, generation, x25519, authority.signCertificate(body))
        }

        /**
         * The structure of a certificate — NOT its signature: [verify] is
         * what makes it trustworthy. BAD_KEY for anything malformed.
         */
        fun parse(bytes: ByteArray): MemberCert {
            if (bytes.size != ENCODED_BYTES || bytes[0] != FORMAT) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "not a member certificate")
            }
            val phone = unpackPhone(bytes.copyOfRange(1, 1 + PHONE_BYTES))
                ?: cryptoError(SmsCryptoException.Code.BAD_KEY, "bad certificate number")
            var at = 1 + PHONE_BYTES
            val generation = bytes[at++].toInt() and 0xFF
            val x25519 = bytes.copyOfRange(at, at + X25519_BYTES)
            at += X25519_BYTES
            return MemberCert(phone, generation, x25519, bytes.copyOfRange(at, at + SIGNATURE_BYTES))
        }

        /** The key id packets name a certificate holder by: a hash of the key. */
        fun keyIdOf(x25519: ByteArray): ByteArray =
            Kdf.sha256(KEY_ID_LABEL, x25519).copyOf(KEY_ID_BYTES)

        private fun signedBody(authorityId: ByteArray, phone: String, generation: Int, x25519: ByteArray) =
            SIGNED_LABEL + authorityId + byteArrayOf(FORMAT) + packPhone(phone) +
                byteArrayOf(generation.toByte()) + x25519

        /** `09` + 9 digits → the 10 digits after the 0, two per byte. */
        private fun packPhone(phone: String): ByteArray {
            val digits = phone.substring(1)
            return ByteArray(PHONE_BYTES) { i ->
                (((digits[2 * i] - '0') shl 4) or (digits[2 * i + 1] - '0')).toByte()
            }
        }

        private fun unpackPhone(packed: ByteArray): String? {
            val out = StringBuilder("0")
            for (b in packed) {
                val hi = (b.toInt() and 0xFF) shr 4
                val lo = b.toInt() and 0x0F
                if (hi > 9 || lo > 9) return null
                out.append('0' + hi).append('0' + lo)
            }
            return out.toString().takeIf(::canName)
        }
    }

    val encoded: ByteArray
        get() = byteArrayOf(FORMAT) + packPhone(phone) + byteArrayOf(generation.toByte()) + x25519 + signature

    val keyId: ByteArray by lazy { keyIdOf(x25519) }

    /**
     * The anchor that signed this certificate, or null when none of
     * [anchors] did (untrusted, altered or forged — the caller cannot tell
     * which, and need not).
     */
    fun verify(anchors: List<AuthorityPublic>): AuthorityPublic? =
        anchors.firstOrNull {
            it.verifyCertificate(signedBody(it.authorityId, phone, generation, x25519), signature)
        }
}
