package com.example.communication_super_app.secure

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class VaultCryptoTest {

    /** A software stand-in for the Keystore layer: real AES-GCM, fixed key. */
    private class SoftwareWrapper : KeyWrapper {
        private val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
        private val random = SecureRandom()

        override fun wrap(plain: ByteArray): ByteArray {
            val iv = ByteArray(12).also(random::nextBytes)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
            return iv + cipher.doFinal(plain)
        }

        override fun unwrap(sealed: ByteArray): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, 12))
            return cipher.doFinal(sealed, 12, sealed.size - 12)
        }

        override fun delete() {}
    }

    /** No device layer at all, so tests can reach the inner blob directly. */
    private object IdentityWrapper : KeyWrapper {
        override fun wrap(plain: ByteArray) = plain.copyOf()
        override fun unwrap(sealed: ByteArray) = sealed.copyOf()
        override fun delete() {}
    }

    // Few rounds: the tests are about the format and the checks, not the cost.
    private val crypto = VaultCrypto(SoftwareWrapper(), iterations = 1_000)

    @Test
    fun `the right PIN opens the sealed key`() {
        val key = crypto.newDataKey()
        val sealed = crypto.seal(key, "1234")
        assertArrayEquals(key, crypto.open(sealed, "1234"))
    }

    @Test
    fun `a wrong PIN is WrongPinException, never a wrong key`() {
        val sealed = crypto.seal(crypto.newDataKey(), "1234")
        for (pin in listOf("1235", "0000", "12345", "123")) {
            assertThrows(VaultCrypto.WrongPinException::class.java) {
                crypto.open(sealed, pin)
            }
        }
    }

    @Test
    fun `the file format survives a round trip`() {
        val key = crypto.newDataKey()
        val text = crypto.seal(key, "2468").serialize()
        assertEquals(true, text.startsWith("hamresan-vault:1:1000:"))
        assertArrayEquals(key, crypto.open(VaultCrypto.Sealed.parse(text), "2468"))
    }

    @Test
    fun `the stored round count is the one used to open`() {
        val strong = VaultCrypto(SoftwareWrapper(), iterations = 5_000)
        val sealed = strong.seal(ByteArray(32) { 7 }, "1111")
        // Opened by an instance configured differently: the file decides.
        assertArrayEquals(ByteArray(32) { 7 }, crypto.open(sealed, "1111"))
    }

    @Test
    fun `sealing twice gives different files (fresh salt and IV)`() {
        val key = crypto.newDataKey()
        val a = crypto.seal(key, "1234")
        val b = crypto.seal(key, "1234")
        assertFalse(a.salt.contentEquals(b.salt))
        assertNotEquals(a.serialize(), b.serialize())
    }

    @Test
    fun `rekey keeps the data key and retires the old PIN`() {
        val key = crypto.newDataKey()
        val old = crypto.seal(key, "1234")
        val rekeyed = crypto.seal(crypto.open(old, "1234"), "9876")
        assertArrayEquals(key, crypto.open(rekeyed, "9876"))
        assertThrows(VaultCrypto.WrongPinException::class.java) {
            crypto.open(rekeyed, "1234")
        }
    }

    @Test
    fun `tampering with the inner ciphertext fails the tag`() {
        val bare = VaultCrypto(IdentityWrapper, iterations = 1_000)
        val sealed = bare.seal(bare.newDataKey(), "1234")
        val tampered = sealed.blob.copyOf().also { it[20] = (it[20].toInt() xor 1).toByte() }
        assertThrows(VaultCrypto.WrongPinException::class.java) {
            bare.open(VaultCrypto.Sealed(sealed.iterations, sealed.salt, tampered), "1234")
        }
    }

    @Test
    fun `a malformed file is CorruptVaultException`() {
        for (text in listOf(
            "",
            "garbage",
            "hamresan-vault:2:1000:00:00", // unknown version
            "hamresan-vault:1:x:00:00", // bad rounds
            "hamresan-vault:1:1000:0:00", // odd hex
            "hamresan-vault:1:1000:zz:00", // not hex
            "other-magic:1:1000:00:00",
        )) {
            assertThrows(text, VaultCrypto.CorruptVaultException::class.java) {
                VaultCrypto.Sealed.parse(text)
            }
        }
    }

    @Test
    fun `an inner blob of the wrong size is corrupt, not a wrong PIN`() {
        val bare = VaultCrypto(IdentityWrapper, iterations = 1_000)
        assertThrows(VaultCrypto.CorruptVaultException::class.java) {
            bare.open(VaultCrypto.Sealed(1_000, ByteArray(16), ByteArray(10)), "1234")
        }
    }

    @Test
    fun `hex round-trips every byte value`() {
        val all = ByteArray(256) { it.toByte() }
        assertArrayEquals(all, Hex.decode(Hex.encode(all)))
        assertEquals("00ff7f80", Hex.encode(byteArrayOf(0, -1, 127, -128)))
    }
}
