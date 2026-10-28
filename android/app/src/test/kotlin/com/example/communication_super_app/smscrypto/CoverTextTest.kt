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

    private fun hash16(word: String) = MessageDigest.getInstance("SHA-256")
        .digest(word.toByteArray(Charsets.UTF_8)).take(8).joinToString("") { "%02x".format(it) }

    private fun packet(size: Int) = ByteArray(size).also { random.nextBytes(it) }

    @Test
    fun `the lists are frozen`() {
        assertEquals(4096, CoverText.PERSIAN.toSet().size)
        assertEquals(4096, CoverText.ENGLISH.toSet().size)
        // A change here is a new cover format, never a new expected value.
        assertEquals("b49e257dacd6cf197529faf098e63fbdc4790c6b65476723c8099f03163d3a16", sha(CoverText.PERSIAN))
        assertEquals("21d84ca428fd99e9974ee612bec95c6b6441a9665280ec5ab9a7427c9dfda0e0", sha(CoverText.ENGLISH))
    }

    @Test
    fun `the words are plain and clean`() {
        val persian = Regex("^[آابپتثجچحخدذرزژسشصضطظعغفقکگلمنوهی]{2,7}$")
        for (w in CoverText.PERSIAN) assertTrue(w, persian.matches(w))
        for (w in CoverText.ENGLISH) assertTrue(w, Regex("^[a-z]{3,8}$").matches(w))
        val blocked = (CoverText.PERSIAN + CoverText.ENGLISH).filter { hash16(it) in COVER_BLOCKED }
        assertEquals(emptyList<String>(), blocked)
    }

    @Test
    fun `every length comes back exactly, in both languages`() {
        // Every padding the 12-bit words can need, and more.
        for (size in 20..80) {
            for (lang in CoverText.Language.values()) {
                val p = packet(size)
                assertArrayEquals("size $size $lang", p, CoverText.decode(CoverText.encode(p, lang)))
            }
        }
        for (size in listOf(120, 255, 398)) {
            val p = packet(size)
            assertArrayEquals(p, CoverText.decode(CoverText.encode(p, CoverText.Language.PERSIAN)))
        }
    }

    @Test
    fun `twelve bits a word`() {
        val p = packet(40)
        val words = CoverText.encode(p, CoverText.Language.PERSIAN).split(' ')
        // 40 bytes + 2 checksum bytes + the padding bit, in 12-bit words.
        assertEquals(((40 + 2) * 8 + 1 + 11) / 12, words.size)
        assertEquals(15, CoverText.MIN_WORDS)
    }

    @Test
    fun `it reads like sentences`() {
        val text = CoverText.encode(packet(120), CoverText.Language.ENGLISH)
        val sentences = text.removeSuffix(".").split(". ")
        assertTrue(sentences.size > 1)
        for (s in sentences) {
            assertTrue(s, s.first().isUpperCase())
            assertTrue(s, s.split(' ').size in 1..12)
        }
        assertTrue(CoverText.encode(packet(30), CoverText.Language.PERSIAN).endsWith("."))
    }

    @Test
    fun `uncover turns a cover text into its wire and leaves the rest alone`() {
        val p = packet(40)
        val wire = Wire.PREFIX + java.util.Base64.getEncoder().withoutPadding().encodeToString(p)
        assertEquals(wire, CoverText.uncover(CoverText.encode(p, CoverText.Language.PERSIAN)))
        assertEquals(wire, CoverText.uncover(CoverText.encode(p, CoverText.Language.ENGLISH)))
        assertArrayEquals(p, Wire.packetBytes(wire))
        for (plain in listOf("سلام، فردا ساعت ۱۰ جلسه داریم.", wire, "", "time year people")) {
            assertEquals(plain, CoverText.uncover(plain))
        }
    }

    @Test
    fun `a keyboard's Arabic letters and extra spacing are forgiven`() {
        val p = packet(30)
        val text = CoverText.encode(p, CoverText.Language.PERSIAN)
            .replace('ی', 'ي').replace('ک', 'ك').replace(" ", "  ")
        assertArrayEquals(p, CoverText.decode(text))
        val english = CoverText.encode(p, CoverText.Language.ENGLISH).uppercase()
        assertArrayEquals(p, CoverText.decode(english))
    }

    @Test
    fun `a changed word, a short text or ordinary words are refused`() {
        val p = packet(30)
        val words = CoverText.encode(p, CoverText.Language.ENGLISH).split(' ').toMutableList()
        val i = words.indexOfFirst { !it.endsWith('.') && it.first().isLowerCase() }
        words[i] = CoverText.ENGLISH.first { it != words[i] }
        assertNull(CoverText.decode(words.joinToString(" ")))
        assertNull(CoverText.decode(CoverText.ENGLISH.take(10).joinToString(" ")))
        assertNull(CoverText.decode(CoverText.PERSIAN.take(40).joinToString(" ")))
        // A dropped word breaks the padding or the checksum, never yields a shorter packet.
        val cover = CoverText.encode(p, CoverText.Language.PERSIAN).split(' ')
        assertNull(CoverText.decode(cover.dropLast(1).joinToString(" ")))
    }
}
