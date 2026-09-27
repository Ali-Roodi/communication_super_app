package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.Kdf
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * A password-protected file: `magic ‖ format ‖ Argon2id cost ‖ salt ‖ nonce`
 * in the clear (and authenticated), then AES-256-GCM under
 * `Argon2id(password, salt)`. The caller canonicalizes the password (a key
 * file's is [Canon.keyFilePassword], the authority's is taken as typed). The key file a member imports and the
 * authority file the Windows tool keeps are both this container, told apart
 * by their magic.
 *
 * A wrong password fails the GCM tag: [SmsCryptoException.Code.WRONG_PASSWORD],
 * never garbage. The cost in the header is checked against
 * [PasswordKdf.acceptable] before anything is derived, so a crafted file
 * cannot make the phone allocate gigabytes.
 */
internal object SealedFile {
    private const val FORMAT = 1
    private const val SALT_BYTES = 16
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128

    fun seal(
        magic: String,
        plain: ByteArray,
        password: ByteArray,
        random: SecureRandom,
        kdf: PasswordKdf,
    ): ByteArray {
        val salt = ByteArray(SALT_BYTES).also(random::nextBytes)
        val nonce = ByteArray(NONCE_BYTES).also(random::nextBytes)
        val header = BinWriter()
            .raw(Kdf.label(magic))
            .u8(FORMAT)
            .u8(kdf.iterations)
            .u32(kdf.memoryKiB.toLong())
            .u8(kdf.parallelism)
            .raw(salt)
            .raw(nonce)
            .toByteArray()
        val key = kdf.derive(password, salt)
        return header + cipher(Cipher.ENCRYPT_MODE, key, nonce, header).doFinal(plain)
    }

    fun open(magic: String, file: ByteArray, password: ByteArray): ByteArray {
        val reader = BinReader(file, SmsCryptoException.Code.NOT_A_KEY_FILE)
        val expected = Kdf.label(magic)
        if (!reader.raw(expected.size).contentEquals(expected) || reader.u8() != FORMAT) {
            reader.fail("not a $magic file")
        }
        val kdf = PasswordKdf(
            iterations = reader.u8(),
            memoryKiB = reader.u32().coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            parallelism = reader.u8(),
        )
        if (!kdf.acceptable) reader.fail("unacceptable key derivation cost")
        val salt = reader.raw(SALT_BYTES)
        val nonce = reader.raw(NONCE_BYTES)
        val headerSize = file.size - reader.remaining
        if (reader.remaining < TAG_BITS / 8) reader.fail("truncated")
        val key = kdf.derive(password, salt)
        return try {
            cipher(Cipher.DECRYPT_MODE, key, nonce, file.copyOf(headerSize))
                .doFinal(file, headerSize, file.size - headerSize)
        } catch (e: AEADBadTagException) {
            cryptoError(SmsCryptoException.Code.WRONG_PASSWORD, "wrong password")
        }
    }

    private fun cipher(mode: Int, key: ByteArray, nonce: ByteArray, header: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            updateAAD(header)
        }
}
