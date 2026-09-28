package com.example.communication_super_app.smscrypto

import java.security.SecureRandom
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class SealedBoxTest {
    private val record = "{\"k\":\"call\",\"number\":\"09120000002\"}".toByteArray()

    @Test
    fun `a sealed record opens with the key pair and nothing else`() {
        val section = IdentityKeyPair.generate(SecureRandom())
        val blob = SealedBox.seal(section.public, record, SecureRandom())
        assertEquals(record.size + SealedBox.OVERHEAD, blob.size)
        assertArrayEquals(record, SealedBox.open(section, blob))

        val other = IdentityKeyPair.generate(SecureRandom())
        expectError(SmsCryptoException.Code.AUTH_FAILED) { SealedBox.open(other, blob) }
    }

    @Test
    fun `sealing twice gives two different blobs`() {
        val section = IdentityKeyPair.generate(SecureRandom())
        val a = SealedBox.seal(section.public, record, SecureRandom())
        val b = SealedBox.seal(section.public, record, SecureRandom())
        assertNotEquals(Kdf.sha256(a).toHex(), Kdf.sha256(b).toHex())
    }

    @Test
    fun `every altered byte is refused`() {
        val section = IdentityKeyPair.generate(SecureRandom())
        val blob = SealedBox.seal(section.public, record, SecureRandom())
        // The ephemeral key, the KEM ciphertext, the sealed record, the tag.
        for (at in listOf(1, 20, 33, 600, 1120, 1121, blob.size - 1)) {
            val altered = blob.copyOf().also { it[at] = (it[at].toInt() xor 0x01).toByte() }
            expectError(SmsCryptoException.Code.AUTH_FAILED) { SealedBox.open(section, altered) }
        }
    }

    @Test
    fun `a blob of another format or too short is not a sealed record`() {
        val section = IdentityKeyPair.generate(SecureRandom())
        val blob = SealedBox.seal(section.public, record, SecureRandom())
        expectError(SmsCryptoException.Code.BAD_PAYLOAD) {
            SealedBox.open(section, blob.copyOf().also { it[0] = 2 })
        }
        expectError(SmsCryptoException.Code.BAD_PAYLOAD) {
            SealedBox.open(section, blob.copyOf(SealedBox.OVERHEAD - 1))
        }
    }

    @Test
    fun `an empty record seals and opens`() {
        val section = IdentityKeyPair.generate(SecureRandom())
        val blob = SealedBox.seal(section.public, ByteArray(0), SecureRandom())
        assertEquals(0, SealedBox.open(section, blob).size)
    }

    /** Pins the format: a change here is a new SealedBox.FORMAT, never a new value. */
    @Test
    fun `golden sealed record`() {
        val section = IdentityKeyPair.fromSeed(ByteArray(32) { it.toByte() })
        val blob = SealedBox.seal(section.public, record, FixedRandom(7))
        assertEquals(GOLDEN, Kdf.sha256(blob).toHex())
        assertArrayEquals(record, SealedBox.open(section, blob))
    }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }

    private companion object {
        const val GOLDEN = "f7778687767663c9121fef8e359e946d73c6fa009e009c2323c124c27a500668"
    }
}
