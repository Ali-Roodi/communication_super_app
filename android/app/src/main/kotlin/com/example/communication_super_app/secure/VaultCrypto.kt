package com.example.communication_super_app.secure

import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * The secure section's key and how it is protected. Pure JVM — no Android
 * types — so it is unit-tested on the build machine (`VaultCryptoTest`).
 *
 * The **data key** (32 random bytes) is what opens `secure.db` (SQLCipher raw
 * key). It is never stored as such; it is sealed twice:
 *
 * 1. **inner** — AES-256-GCM under a key derived from the app PIN
 *    (PBKDF2-HMAC-SHA256, per-vault salt). The GCM tag is also the PIN check:
 *    a wrong PIN fails authentication, it never yields a wrong key.
 * 2. **outer** — the inner blob is sealed again by a [KeyWrapper], on the
 *    device a non-exportable Android Keystore key. So the vault file copied off
 *    the phone cannot be attacked offline at all: without the Keystore key
 *    there is nothing to run PIN guesses against.
 *
 * The on-disk format is one versioned line; see [Sealed]. Hex and plain text
 * rather than Base64/JSON on purpose: `java.util.Base64` is API 26 (minSdk is
 * 24) and `org.json` is an Android stub that does not run in a JVM test.
 */
class VaultCrypto(
    private val wrapper: KeyWrapper,
    private val iterations: Int = DEFAULT_ITERATIONS,
    private val random: SecureRandom = SecureRandom(),
) {
    companion object {
        const val FORMAT_VERSION = 1
        const val KEY_BYTES = 32
        private const val SALT_BYTES = 16
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128

        /**
         * PBKDF2 rounds. The Keystore layer is what stops offline guessing;
         * this is the cost of each guess made *on* the device, and the price
         * of every unlock. Stored per vault, so it can be raised later without
         * breaking an existing one.
         */
        const val DEFAULT_ITERATIONS = 210_000

        /** Binds the inner ciphertext to this purpose and format version. */
        private val AAD = "hamresan.secure-vault.v1".toByteArray(Charsets.US_ASCII)
    }

    /** A wrong PIN — the inner GCM tag did not verify. */
    class WrongPinException : Exception("wrong PIN")

    /** The file is not a vault this code can read. */
    class CorruptVaultException(message: String, cause: Throwable? = null) :
        Exception(message, cause)

    /**
     * What is written to disk:
     * `hamresan-vault:<version>:<pbkdf2 rounds>:<salt hex>:<outer blob hex>`.
     * The KDF is fixed by the version (PBKDF2-HMAC-SHA256).
     */
    class Sealed(val iterations: Int, val salt: ByteArray, val blob: ByteArray) {
        fun serialize(): String =
            "$MAGIC:$FORMAT_VERSION:$iterations:${Hex.encode(salt)}:${Hex.encode(blob)}"

        companion object {
            private const val MAGIC = "hamresan-vault"

            fun parse(text: String): Sealed {
                val parts = text.trim().split(':')
                if (parts.size != 5 || parts[0] != MAGIC) {
                    throw CorruptVaultException("not a vault file")
                }
                val version = parts[1].toIntOrNull()
                if (version != FORMAT_VERSION) {
                    throw CorruptVaultException("unsupported vault version ${parts[1]}")
                }
                val iterations = parts[2].toIntOrNull()
                    ?: throw CorruptVaultException("bad iteration count")
                return Sealed(iterations, Hex.decode(parts[3]), Hex.decode(parts[4]))
            }
        }
    }

    /** A fresh random data key. */
    fun newDataKey(): ByteArray = ByteArray(KEY_BYTES).also(random::nextBytes)

    /** Seals [dataKey] under [pin] (and the device wrapper). */
    fun seal(dataKey: ByteArray, pin: String): Sealed {
        require(dataKey.size == KEY_BYTES) { "data key must be $KEY_BYTES bytes" }
        val salt = ByteArray(SALT_BYTES).also(random::nextBytes)
        val kek = deriveKek(pin, salt, iterations)
        val iv = ByteArray(IV_BYTES).also(random::nextBytes)
        val inner = gcm(Cipher.ENCRYPT_MODE, kek, iv).doFinal(dataKey)
        return Sealed(iterations, salt, wrapper.wrap(iv + inner))
    }

    /**
     * Recovers the data key.
     *
     * @throws WrongPinException for a wrong PIN.
     * @throws CorruptVaultException for a malformed blob.
     * Anything the [KeyWrapper] throws (a lost Keystore key) propagates as is.
     */
    fun open(sealed: Sealed, pin: String): ByteArray {
        val inner = wrapper.unwrap(sealed.blob)
        if (inner.size != IV_BYTES + KEY_BYTES + TAG_BITS / 8) {
            throw CorruptVaultException("inner blob has the wrong size")
        }
        val kek = deriveKek(pin, sealed.salt, sealed.iterations)
        val iv = inner.copyOfRange(0, IV_BYTES)
        return try {
            gcm(Cipher.DECRYPT_MODE, kek, iv).doFinal(inner, IV_BYTES, inner.size - IV_BYTES)
        } catch (e: AEADBadTagException) {
            throw WrongPinException()
        }
    }

    private fun deriveKek(pin: String, salt: ByteArray, rounds: Int): SecretKeySpec {
        if (rounds < 1) throw CorruptVaultException("bad iteration count")
        val spec = PBEKeySpec(pin.toCharArray(), salt, rounds, KEY_BYTES * 8)
        try {
            val bytes = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
                .generateSecret(spec).encoded
            return SecretKeySpec(bytes, "AES")
        } finally {
            spec.clearPassword()
        }
    }

    private fun gcm(mode: Int, key: SecretKeySpec, iv: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, key, GCMParameterSpec(TAG_BITS, iv))
            updateAAD(AAD)
        }
}

/** The device-binding layer. On a phone: [KeystoreKeyWrapper]. */
interface KeyWrapper {
    fun wrap(plain: ByteArray): ByteArray
    fun unwrap(sealed: ByteArray): ByteArray
    fun delete()
}

/** Lowercase hex, without Android types, so this file stays pure JVM. */
object Hex {
    private const val DIGITS = "0123456789abcdef"

    fun encode(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append(DIGITS[v ushr 4]).append(DIGITS[v and 0x0F])
        }
        return out.toString()
    }

    fun decode(text: String): ByteArray {
        if (text.length % 2 != 0) throw VaultCrypto.CorruptVaultException("odd hex length")
        return ByteArray(text.length / 2) { i ->
            val hi = Character.digit(text[2 * i], 16)
            val lo = Character.digit(text[2 * i + 1], 16)
            if (hi < 0 || lo < 0) throw VaultCrypto.CorruptVaultException("bad hex")
            ((hi shl 4) or lo).toByte()
        }
    }
}
