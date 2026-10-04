package com.example.communication_super_app.smscrypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class TimedPayloadTest {
    private val gid = ByteArray(Payload.GROUP_ID_BYTES) { (it + 9).toByte() }

    @Test
    fun `a timed message carries its lifetime in either encoding`() {
        for (text in listOf("این پیام پاک می‌شود", "gone soon")) {
            for (ttl in listOf(30L, 3600L, Payload.MAX_TTL_SECONDS)) {
                val p = Payload.parse(Payload.text(text, ttlSeconds = ttl)) as Payload.Text
                assertEquals(text, p.text)
                assertEquals(ttl, p.ttlSeconds)
                assertNull(p.groupId)
            }
        }
        assertNull((Payload.parse(Payload.text("x")) as Payload.Text).ttlSeconds)
    }

    @Test
    fun `a timed group message keeps both its id and its lifetime`() {
        val p = Payload.parse(Payload.groupText(gid, "سلام", true, 300)) as Payload.Text
        assertArrayEquals(gid, p.groupId)
        assertEquals(300L, p.ttlSeconds)
        assertEquals(true, p.deleteAfterSeen)
        assertEquals("سلام", p.text)
    }

    @Test
    fun `the lifetime costs its varint and nothing else`() {
        val text = "جلسه ساعت ۱۰"
        assertEquals(Payload.text(text).size + 2, Payload.text(text, ttlSeconds = 300).size)
        assertEquals(Payload.text(text).size + 1, Payload.text(text, ttlSeconds = 30).size)
    }

    @Test
    fun `a bad lifetime is refused both ways`() {
        assertThrows(IllegalArgumentException::class.java) { Payload.text("x", ttlSeconds = 0) }
        assertThrows(IllegalArgumentException::class.java) {
            Payload.text("x", ttlSeconds = Payload.MAX_TTL_SECONDS + 1)
        }
        // Flag set, lifetime 0 on the wire.
        val zero = byteArrayOf((Payload.KIND_TEXT_UTF8 or Payload.FLAG_TIMED).toByte(), 0, 'x'.code.toByte())
        assertThrows(SmsCryptoException::class.java) { Payload.parse(zero) }
        // Flag set, nothing after it.
        val cut = byteArrayOf((Payload.KIND_TEXT_UTF8 or Payload.FLAG_TIMED).toByte())
        assertThrows(SmsCryptoException::class.java) { Payload.parse(cut) }
        // Never on a control kind.
        val control = Payload.seen(1, 2).also { it[0] = (it[0].toInt() or Payload.FLAG_TIMED).toByte() }
        assertThrows(SmsCryptoException::class.java) { Payload.parse(control) }
    }
}
