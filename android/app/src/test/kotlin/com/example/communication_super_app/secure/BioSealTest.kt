package com.example.communication_super_app.secure

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Pins the file format of the secure section's biometric copy. */
class BioSealTest {
    private val iv = ByteArray(12) { it.toByte() }
    private val sealed = ByteArray(48) { (0xA0 + it).toByte() }

    @Test
    fun roundTrips() {
        val seal = BioSeal(iv, sealed)
        val parsed = BioSeal.parse(seal.serialize())!!
        assertArrayEquals(iv, parsed.iv)
        assertArrayEquals(sealed, parsed.sealed)
        assertEquals(seal, parsed)
    }

    @Test
    fun formatIsPinned() {
        val text = BioSeal(iv, sealed).serialize()
        assertEquals("hamresan-vault-bio:1:000102030405060708090a0b:", text.substringBeforeLast(':') + ":")
        assertEquals(96, text.substringAfterLast(':').length)
    }

    @Test
    fun refusesAnythingElse() {
        val good = BioSeal(iv, sealed).serialize()
        assertNull(BioSeal.parse(""))
        assertNull(BioSeal.parse(good.replace("hamresan-vault-bio", "hamresan-vault")))
        assertNull(BioSeal.parse(good.replace(":1:", ":2:")))
        // Wrong IV length, a body no longer than the tag, bad hex.
        assertNull(BioSeal.parse(BioSeal(ByteArray(8), sealed).serialize()))
        assertNull(BioSeal.parse(BioSeal(iv, ByteArray(16)).serialize()))
        assertNull(BioSeal.parse(good.dropLast(1) + "z"))
        assertNull(BioSeal.parse(good.dropLast(1)))
        // The PIN vault's own file is never mistaken for it.
        assertNull(BioSeal.parse("hamresan-vault:1:210000:00:00"))
    }
}
