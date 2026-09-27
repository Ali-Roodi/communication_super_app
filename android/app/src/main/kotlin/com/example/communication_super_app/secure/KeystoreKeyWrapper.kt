package com.example.communication_super_app.secure

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The device-binding layer of the secure vault: AES-256-GCM under a key that
 * lives in the Android Keystore and cannot be exported.
 *
 * The key needs no user authentication of its own — the app PIN is the
 * authentication, applied in the inner layer ([VaultCrypto]). What this layer
 * adds is that the sealed vault means nothing anywhere but on this device, so
 * the 4-digit PIN cannot be brute-forced offline from a copied file.
 *
 * StrongBox is used where the device has it and falls back to the TEE.
 */
class KeystoreKeyWrapper(private val alias: String = DEFAULT_ALIAS) : KeyWrapper {
    companion object {
        const val DEFAULT_ALIAS = "hamresan_secure_vault_v1"
        private const val PROVIDER = "AndroidKeyStore"
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
        private const val TAG = "KeystoreKeyWrapper"
    }

    /** The Keystore key is gone (app data cleared, a broken Keystore). */
    class KeyLostException(message: String) : Exception(message)

    private fun keyStore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    private fun existingKey(): SecretKey? =
        (keyStore().getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey

    private fun createKey(): SecretKey {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .apply {
                if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setIsStrongBoxBacked(true)
                }
            }
            .build()

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generator.init(spec(strongBox = true))
                return generator.generateKey()
            } catch (e: Exception) {
                // StrongBoxUnavailableException is API 28 and is not the only
                // way a StrongBox request fails in the field; any failure here
                // falls back to the TEE, which is the normal case anyway.
                Log.i(TAG, "StrongBox not used (${e.javaClass.simpleName}); using the TEE")
            }
        }
        generator.init(spec(strongBox = false))
        return generator.generateKey()
    }

    /** Sealing creates the key if there is none yet — only a new vault seals. */
    override fun wrap(plain: ByteArray): ByteArray {
        val key = existingKey() ?: createKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key) // the Keystore picks the IV
        val iv = cipher.iv
        check(iv.size == IV_BYTES) { "unexpected IV length ${iv.size}" }
        return iv + cipher.doFinal(plain)
    }

    /** Opening never creates a key: a missing one means the vault is lost. */
    override fun unwrap(sealed: ByteArray): ByteArray {
        val key = existingKey() ?: throw KeyLostException("Keystore key $alias is missing")
        if (sealed.size <= IV_BYTES) throw VaultCrypto.CorruptVaultException("outer blob too short")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(TAG_BITS, sealed, 0, IV_BYTES),
        )
        return try {
            cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES)
        } catch (e: javax.crypto.AEADBadTagException) {
            // The outer layer does not depend on the PIN, so a tag failure here
            // is a key that no longer matches this vault, not a wrong PIN.
            throw KeyLostException("Keystore key does not open this vault")
        }
    }

    override fun delete() {
        try {
            keyStore().deleteEntry(alias)
        } catch (e: Exception) {
            Log.w(TAG, "Could not delete Keystore key: ${e.message}")
        }
    }
}
