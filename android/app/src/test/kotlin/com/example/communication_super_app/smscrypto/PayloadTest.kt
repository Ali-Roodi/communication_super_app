package com.example.communication_super_app.smscrypto

import java.security.MessageDigest
import org.bouncycastle.util.encoders.Hex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PayloadTest {
    private fun roundTrip(text: String): ByteArray {
        val payload = Payload.text(text)
        assertEquals(text, (Payload.parse(payload) as Payload.Text).text)
        return payload
    }

    private val zwnj = 0x200C.toChar()

    private fun table(): String = PersianCodePage.decode(ByteArray(97) { (0x80 + it).toByte() })!!

    @Test
    fun `Persian text takes one byte a letter`() {
        val text = "می${zwnj}خواهم فردا ساعت ۱۰ «جلسه» را ببینم؛ باشد؟"
        val payload = roundTrip(text)
        assertEquals(Payload.KIND_TEXT_FA, payload[0].toInt())
        assertEquals(1 + text.length, payload.size)
        assertTrue(payload.size < text.toByteArray(Charsets.UTF_8).size)
    }

    @Test
    fun `one emoji does not double the whole message`() {
        val text = "سلام دوست من 😀"
        val payload = roundTrip(text)
        assertEquals(Payload.KIND_TEXT_FA, payload[0].toInt())
        // 13 table/ASCII characters, then an escape and four UTF-8 bytes.
        assertEquals(1 + 13 + 1 + 4, payload.size)
    }

    @Test
    fun `text the code page does not help stays UTF-8`() {
        assertEquals(Payload.KIND_TEXT_UTF8, roundTrip("Привет, как дела?")[0].toInt())
        assertEquals(Payload.KIND_TEXT_UTF8, roundTrip("")[0].toInt())
        roundTrip("plain ASCII\nwith a newline\tand a tab")
        roundTrip("ي ك ة ۀ ـ ٪ ٫ ٬ ٠١٢ ۰۱۲ … – — “ ” ‘ ’ ﷼ • × ÷")
    }

    @Test
    fun `every table character round-trips`() {
        val all = table()
        assertEquals(97, all.length)
        assertEquals(97, all.toSet().size)
        assertEquals(all, (Payload.parse(Payload.text(all)) as Payload.Text).text)
        assertEquals(97 + 1, Payload.text(all).size)
    }

    @Test
    fun `the code page table is frozen`() {
        // Sent messages are decoded through this table for ever. If this
        // fails, the table was edited: revert it and add a new payload kind.
        assertEquals(
            FROZEN_TABLE_SHA256,
            Hex.toHexString(MessageDigest.getInstance("SHA-256").digest(table().toByteArray(Charsets.UTF_8))),
        )
    }

    @Test
    fun `bytes no encoder produced are BAD_PAYLOAD`() {
        val fa = Payload.KIND_TEXT_FA.toByte()
        val utf8 = Payload.KIND_TEXT_UTF8.toByte()
        val bad = listOf(
            byteArrayOf(),
            byteArrayOf(0x7F, 0x41),
            byteArrayOf(fa, 0xE1.toByte()),
            byteArrayOf(fa, 0xFF.toByte()),
            byteArrayOf(fa, 0xFF.toByte(), 0x80.toByte()),
            byteArrayOf(fa, 0xFF.toByte(), 0xC0.toByte(), 0x80.toByte()),
            byteArrayOf(fa, 0xFF.toByte(), 0xF0.toByte(), 0x9F.toByte()),
            byteArrayOf(utf8, 0xC3.toByte()),
            byteArrayOf(utf8, 0xED.toByte(), 0xA0.toByte(), 0x80.toByte()),
        )
        for (bytes in bad) {
            expectError(SmsCryptoException.Code.BAD_PAYLOAD) { Payload.parse(bytes) }
        }
        assertNull(PersianCodePage.decode(byteArrayOf(0xFE.toByte())))
    }

    @Test
    fun `delete-after-seen is one bit on the text kind`() {
        val plain = Payload.text("سلام")
        val flagged = Payload.text("سلام", deleteAfterSeen = true)
        assertEquals(plain.size, flagged.size)
        assertEquals(Payload.KIND_TEXT_FA or Payload.FLAG_DELETE_AFTER_SEEN, flagged[0].toInt() and 0xFF)
        val t = Payload.parse(flagged) as Payload.Text
        assertEquals("سلام", t.text)
        assertTrue(t.deleteAfterSeen)
        assertTrue(!(Payload.parse(plain) as Payload.Text).deleteAfterSeen)
        val latin = Payload.parse(Payload.text("Привет", deleteAfterSeen = true)) as Payload.Text
        assertTrue(latin.deleteAfterSeen)
    }

    @Test
    fun `seen and delete name a message by session and counter`() {
        val seen = Payload.parse(Payload.seen(0xBEEF, 300)) as Payload.Seen
        assertEquals(0xBEEF, seen.sid)
        assertEquals(300L, seen.upTo)
        val delete = Payload.parse(Payload.delete(7, 0)) as Payload.Delete
        assertEquals(7, delete.sid)
        assertEquals(0L, delete.counter)
        assertEquals(4, Payload.seen(1, 0).size) // kind, sid, one counter byte
        for (bad in listOf(
            byteArrayOf(0x10),
            byteArrayOf(0x10, 0, 1),
            byteArrayOf(0x10, 0, 1, 1, 0),
            byteArrayOf(0x90.toByte(), 0, 1, 1), // the flag on a control kind
            byteArrayOf(0x11, 0, 1, 0x80.toByte(), 0),
        )) {
            expectError(SmsCryptoException.Code.BAD_PAYLOAD) { Payload.parse(bad) }
        }
    }

    private companion object {
        const val FROZEN_TABLE_SHA256 = "fcab63c00d891aadf740a133f04c3f95488a354ae3a59a84d733f8035ca3b724"
    }
}
