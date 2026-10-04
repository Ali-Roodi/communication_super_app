package com.example.communication_super_app.smscrypto

import java.security.MessageDigest
import java.security.SecureRandom
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoverTextTest {
    private val random = SecureRandom()

    private fun sha(list: List<String>) = MessageDigest.getInstance("SHA-256")
        .digest(list.joinToString(" ").toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    @Test
    fun `the lists are frozen`() {
        assertEquals(256, CoverText.PERSIAN.toSet().size)
        assertEquals(256, CoverText.ENGLISH.toSet().size)
        // A change here is a new cover format, never a new expected value.
        assertEquals("4c74cd260ec564a307ee9508a9c78f523cf76643c11d2c5b7b9c05e68a151994", sha(CoverText.PERSIAN))
        assertEquals("f76e1d1f88818fa1f4321054201bc58d1aa0bf2e302fe2814aa284905abad93b", sha(CoverText.ENGLISH))
    }

    @Test
    fun `every packet comes back exactly, in both languages`() {
        for (size in listOf(20, 21, 47, 120, 300)) {
            val packet = ByteArray(size).also { random.nextBytes(it) }
            for (lang in CoverText.Language.values()) {
                val text = CoverText.encode(packet, lang)
                assertArrayEquals(packet, CoverText.decode(text))
            }
        }
    }

    @Test
    fun `uncover turns a cover text into its wire and leaves the rest alone`() {
        val packet = ByteArray(40).also { random.nextBytes(it) }
        val wire = Wire.PREFIX + java.util.Base64.getEncoder().withoutPadding().encodeToString(packet)
        assertEquals(wire, CoverText.uncover(CoverText.encode(packet, CoverText.Language.PERSIAN)))
        assertEquals(wire, CoverText.uncover(CoverText.encode(packet, CoverText.Language.ENGLISH)))
        assertArrayEquals(packet, Wire.packetBytes(wire))
        for (plain in listOf("سلام، فردا ساعت ۱۰ جلسه داریم.", wire, "", "time year people")) {
            assertEquals(plain, CoverText.uncover(plain))
        }
    }

    @Test
    fun `a keyboard's Arabic letters and extra spacing are forgiven`() {
        val packet = ByteArray(30).also { random.nextBytes(it) }
        val text = CoverText.encode(packet, CoverText.Language.PERSIAN)
            .replace('ی', 'ي').replace('ک', 'ك').replace(" ", "  ")
        assertArrayEquals(packet, CoverText.decode(text))
        val english = CoverText.encode(packet, CoverText.Language.ENGLISH).uppercase()
        assertArrayEquals(packet, CoverText.decode(english))
    }

    @Test
    fun `a changed word, a short text or ordinary words are refused`() {
        val packet = ByteArray(30).also { random.nextBytes(it) }
        val words = CoverText.encode(packet, CoverText.Language.ENGLISH).split(' ').toMutableList()
        val i = words.indexOfFirst { !it.endsWith('.') }
        words[i] = CoverText.ENGLISH.first { it != words[i] }
        assertNull(CoverText.decode(words.joinToString(" ")))
        assertNull(CoverText.decode(CoverText.ENGLISH.take(10).joinToString(" ")))
        assertNull(CoverText.decode(CoverText.PERSIAN.take(40).joinToString(" ")))
        assertTrue(CoverText.encode(packet, CoverText.Language.PERSIAN).endsWith("."))
    }
}
