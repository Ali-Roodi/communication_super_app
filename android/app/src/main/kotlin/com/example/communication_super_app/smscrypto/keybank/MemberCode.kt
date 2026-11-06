package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.Kdf
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
import java.math.BigInteger
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters

/**
 * «کد ۱۶ نویسه‌ای»: the second way to a member's key, for when a file cannot be
 * sent. The code can be read out over the phone; with the member's password
 * (the same one as their key file) the app builds **exactly** what the key
 * file holds, byte for byte — the same identity and the same certificate.
 *
 * A certificate needs the authority's 64-byte signature, which no short code
 * can carry, so the authority's Ed25519 seed is built into the app, sealed
 * ([sealSigner]) under the organization's unlock secret `U`. Design decision
 * (1405/08/15), with its cost accepted: whoever holds one valid code and its
 * password can open that seal and sign a certificate for any number. What they
 * still cannot do is read anybody's messages: a member's private key also
 * depends on that member's own password, which only the authority can produce.
 *
 * ```
 * password (20 chars, 100 bits) = tag(62) ‖ (number(30) ‖ generation(8)) xor hash(tag)
 * Argon2id(password)            = mask(10) ‖ K(32)
 * code (16 chars, 80 bits)      = U(10) xor mask
 * identity seed                 = HKDF(K ‖ U, number ‖ generation)
 * seal key                      = Argon2id(U)
 * ```
 *
 * The password carries the number and generation, so a member types only the
 * code and the password. Nothing is checksummed: a typo anywhere fails the
 * seal's GCM tag, and nothing is built.
 *
 * **Frozen**: `KeyBankTest` pins all of it. A change re-keys every member.
 */
object MemberCode {
    const val CODE_CHARS = 16
    const val PASSWORD_CHARS = 20
    const val UNLOCK_BYTES = 10

    /** The sealed signer: the Ed25519 seed + the GCM tag. */
    const val SEALED_SIGNER_BYTES = 32 + 16

    private const val ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    private const val TAG_BITS = 62
    private const val GENERATION_BITS = 8
    private const val NAME_BITS = 30 + GENERATION_BITS
    private const val MEMBER_SECRET_BYTES = 32
    private const val MAX_NUMBER = 999_999_999L
    private const val GCM_TAG_BITS = 128

    /** Part of the derivation, not a setting: not [PasswordKdf.KEY_FILE], which may change. */
    private val STRETCH = PasswordKdf(iterations = 3, memoryKiB = 64 * 1024, parallelism = 1)

    private val STRETCH_SALT = Kdf.label("hamresan.member-code.stretch.v1")
    private val SEAL_SALT = Kdf.label("hamresan.member-code.seal.v1")
    private val NAME_LABEL = Kdf.label("hamresan.member-code.name.v1")
    private val IDENTITY_SALT = Kdf.label("hamresan.member-code.identity.v1")

    /** A trust anchor and its sealed Ed25519 seed. */
    class Signer(val authority: AuthorityPublic, val sealed: ByteArray)

    /** The number and generation a password carries. */
    class Named(val phone: String, val generation: Int)

    private class Stretched(val mask: ByteArray, val memberSecret: ByteArray)

    /**
     * Builds the member's key and certificate from what they typed. A wrong
     * code or password, or a code of another member, is WRONG_PASSWORD and
     * nothing has been built. The opened seed is wiped before returning.
     */
    fun open(code: String, password: String, signers: List<Signer>): KeyFile.Opened {
        val typed = read(code, CODE_CHARS) ?: wrong()
        val named = named(password) ?: wrong()
        val stretched = stretch(password)
        val unlock = xor(toBytes(typed, UNLOCK_BYTES), stretched.mask)
        val sealKey = sealKey(unlock)
        for (signer in signers) {
            val seed = try {
                cipher(Cipher.DECRYPT_MODE, sealKey, signer.authority.authorityId).doFinal(signer.sealed)
            } catch (e: AEADBadTagException) {
                continue
            }
            try {
                val identity = identity(stretched.memberSecret, unlock, named.phone, named.generation)
                val cert = MemberCert.issue(
                    Ed25519PrivateKeyParameters(seed, 0),
                    signer.authority.authorityId,
                    named.phone,
                    named.generation,
                    identity,
                )
                val verified = cert.verify(listOf(signer.authority))
                    ?: cryptoError(SmsCryptoException.Code.BAD_BUNDLE, "the sealed signer is not the anchor's")
                return KeyFile.Opened(identity, cert, verified)
            } finally {
                seed.fill(0)
            }
        }
        wrong()
    }

    /** What [password] says about itself; null when it cannot be a member's password. */
    fun named(password: String): Named? {
        val packed = read(password, PASSWORD_CHARS) ?: return null
        val tag = packed.shiftRight(NAME_BITS)
        val name = packed.xor(tag.shiftLeft(NAME_BITS)).xor(nameMask(tag))
        val number = name.shiftRight(GENERATION_BITS).toLong()
        if (number > MAX_NUMBER) return null
        return Named(
            "09" + number.toString().padStart(9, '0'),
            name.and(BigInteger.valueOf(255)).toInt(),
        )
    }

    // ── The authority's side ────────────────────────────────────────────────

    /** [secret] is the authority's own material for this member, at least 8 bytes. */
    internal fun password(secret: ByteArray, phone: String, generation: Int): String {
        require(MemberCert.canName(phone)) { "a member code names a mobile number (09…)" }
        require(generation in 0..MemberCert.MAX_GENERATION) { "generation 0..${MemberCert.MAX_GENERATION}" }
        val tag = BigInteger(1, secret.copyOf(8)).shiftRight(64 - TAG_BITS)
        val name = BigInteger.valueOf(phone.substring(2).toLong())
            .shiftLeft(GENERATION_BITS)
            .or(BigInteger.valueOf(generation.toLong()))
        return write(tag.shiftLeft(NAME_BITS).or(name.xor(nameMask(tag))), PASSWORD_CHARS)
    }

    internal fun code(unlock: ByteArray, password: String): String =
        write(BigInteger(1, xor(unlock, stretch(password).mask)), CODE_CHARS)

    internal fun identity(unlock: ByteArray, password: String, phone: String, generation: Int): IdentityKeyPair =
        identity(stretch(password).memberSecret, unlock, phone, generation)

    /** [seed] under the organization's [unlock] secret; deterministic. */
    internal fun sealSigner(seed: ByteArray, unlock: ByteArray, authorityId: ByteArray): ByteArray =
        cipher(Cipher.ENCRYPT_MODE, sealKey(unlock), authorityId).doFinal(seed)

    // ── Both sides: the one derivation ──────────────────────────────────────

    private fun identity(memberSecret: ByteArray, unlock: ByteArray, phone: String, generation: Int): IdentityKeyPair {
        val info = BinWriter().text(phone).u32(generation.toLong()).toByteArray()
        return IdentityKeyPair.fromSeed(
            Kdf.hkdf(memberSecret + unlock, IDENTITY_SALT, info, IdentityKeyPair.SEED_BYTES),
        )
    }

    private fun stretch(password: String): Stretched {
        val out = STRETCH.derive(
            Canon.keyFilePassword(password).toByteArray(Charsets.US_ASCII),
            STRETCH_SALT,
            UNLOCK_BYTES + MEMBER_SECRET_BYTES,
        )
        return Stretched(out.copyOf(UNLOCK_BYTES), out.copyOfRange(UNLOCK_BYTES, out.size))
    }

    /** Memory-hard: the seal ships in every APK, and this is what guards it against guessing `U`. */
    private fun sealKey(unlock: ByteArray): ByteArray = STRETCH.derive(unlock, SEAL_SALT)

    /** A fixed nonce: each authority's seal key encrypts this one seed, always to the same bytes. */
    private fun cipher(mode: Int, key: ByteArray, authorityId: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, ByteArray(12)))
            updateAAD(authorityId)
        }

    /** Keeps the number from showing in the password; whoever holds the password may read it. */
    private fun nameMask(tag: BigInteger): BigInteger =
        BigInteger(1, Kdf.sha256(NAME_LABEL, toBytes(tag, 8))).shiftRight(256 - NAME_BITS)

    private fun wrong(): Nothing =
        cryptoError(SmsCryptoException.Code.WRONG_PASSWORD, "wrong code or password")

    private fun xor(a: ByteArray, b: ByteArray) = ByteArray(a.size) { (a[it].toInt() xor b[it].toInt()).toByte() }

    private fun toBytes(value: BigInteger, size: Int): ByteArray {
        val raw = value.toByteArray()
        val out = ByteArray(size)
        val n = minOf(raw.size, size)
        System.arraycopy(raw, raw.size - n, out, size - n, n)
        return out
    }

    /** Groups of four, as a person reads it out. */
    private fun write(value: BigInteger, chars: Int): String {
        val out = CharArray(chars)
        var rest = value
        for (i in chars - 1 downTo 0) {
            out[i] = ALPHABET[rest.and(BigInteger.valueOf(31)).toInt()]
            rest = rest.shiftRight(5)
        }
        return String(out).chunked(4).joinToString("-")
    }

    /** Case, dashes and spaces do not matter ([Canon.keyFilePassword]). */
    private fun read(text: String, chars: Int): BigInteger? {
        val canon = Canon.keyFilePassword(text)
        if (canon.length != chars) return null
        var value = BigInteger.ZERO
        for (c in canon) {
            val digit = ALPHABET.indexOf(c)
            if (digit < 0) return null
            value = value.shiftLeft(5).or(BigInteger.valueOf(digit.toLong()))
        }
        return value
    }
}
