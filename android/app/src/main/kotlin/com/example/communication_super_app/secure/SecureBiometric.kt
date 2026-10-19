package com.example.communication_super_app.secure

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * «باز کردن بخش امن با اثر انگشت» — the secure section's data key, sealed a
 * second time under a Keystore key that only a **strong** biometric can use.
 *
 * The vault itself ([VaultCrypto]) is unchanged: the data key stays sealed
 * under the section PIN, and this is a second, independent copy. The key:
 *
 * - requires a strong (Class 3) biometric **for every single use**
 *   (`setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`; on Android
 *   9–10 the per-use default) — so the system releases it only through a
 *   `BiometricPrompt` bound to the one cipher it was asked for, and the app
 *   never holds a key that could decrypt without a finger;
 * - is destroyed by the system when a biometric is enrolled or all are
 *   removed (`setInvalidatedByBiometricEnrollment`), so somebody who knows
 *   the *phone's* PIN cannot add their own finger and walk in — the next use
 *   fails with [KeyPermanentlyInvalidatedException] and the copy is deleted;
 * - is never the phone's PIN or pattern (no device credential).
 *
 * Weak biometrics (most face unlocks, including Samsung's) cannot unlock a
 * Keystore key at all; on such a phone only a fingerprint can be used here.
 */
object SecureBiometric {
    const val ALIAS = "hamresan_secure_biometric_v1"
    private const val PROVIDER = "AndroidKeyStore"
    private const val TAG_BITS = 128
    private const val TAG = "SecureBiometric"

    /** The copy can no longer be opened (new enrollment, lock removed). */
    class InvalidatedException : Exception("biometric key invalidated")

    private fun keyStore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    /** A new key, replacing any old one; the cipher to seal the data key with. */
    fun newEncryptCipher(): Cipher {
        delete()
        val builder = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(builder.build())
        val key = generator.generateKey()
        return Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
    }

    /** The cipher to open [seal] with, once a finger has authorised it. */
    fun decryptCipher(seal: BioSeal): Cipher {
        val key = keyStore().getKey(ALIAS, null) as? SecretKey ?: throw InvalidatedException()
        return try {
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, seal.iv))
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw InvalidatedException()
        }
    }

    fun delete() {
        try {
            val store = keyStore()
            if (store.containsAlias(ALIAS)) store.deleteEntry(ALIAS)
        } catch (e: Exception) {
            Log.w(TAG, "key delete failed: ${e.javaClass.simpleName}")
        }
    }
}

/**
 * The file format of the biometric copy:
 * `hamresan-vault-bio:1:<iv hex>:<ciphertext+tag hex>`. Pure, so the JVM tests
 * pin it ([BioSealTest]).
 */
data class BioSeal(val iv: ByteArray, val sealed: ByteArray) {
    companion object {
        private const val MAGIC = "hamresan-vault-bio"
        private const val VERSION = 1

        /** Null for anything that is not a well-formed version-1 seal. */
        fun parse(text: String): BioSeal? {
            val parts = text.trim().split(':')
            if (parts.size != 4 || parts[0] != MAGIC || parts[1] != VERSION.toString()) return null
            return try {
                val iv = Hex.decode(parts[2])
                val sealed = Hex.decode(parts[3])
                if (iv.size != 12 || sealed.size <= 16) null else BioSeal(iv, sealed)
            } catch (e: VaultCrypto.CorruptVaultException) {
                null
            }
        }
    }

    fun serialize(): String = "$MAGIC:$VERSION:${Hex.encode(iv)}:${Hex.encode(sealed)}"

    override fun equals(other: Any?): Boolean =
        other is BioSeal && iv.contentEquals(other.iv) && sealed.contentEquals(other.sealed)

    override fun hashCode(): Int = 31 * iv.contentHashCode() + sealed.contentHashCode()
}
