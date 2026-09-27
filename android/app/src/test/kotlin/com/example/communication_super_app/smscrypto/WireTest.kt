package com.example.communication_super_app.smscrypto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WireTest {
    /** The characters [Wire.encode] may emit — all GSM 03.38 basic, one septet each. */
    private val gsmSafe = ('A'..'Z') + ('a'..'z') + ('0'..'9') + listOf('+', '/', '#', ':')

    private val session = handshake(Members())

    private fun assertGsm7(wire: String) {
        for (c in wire) assertTrue("'$c' is not a single GSM-7 septet", c in gsmSafe)
    }

    @Test
    fun `everything on the wire is plain GSM-7`() {
        assertGsm7(session.initWire)
        assertGsm7(session.responseWire)
        assertGsm7(session.alice.send("سلام، حال شما چطور است؟ 😀").wire)
        assertTrue(session.initWire.startsWith(Wire.PREFIX))
    }

    @Test
    fun `a Persian message of up to 96 letters is one SMS`() {
        val fits = session.alice.send("س".repeat(96)).wire
        assertEquals(159, fits.length)
        assertEquals(1, Wire.smsParts(fits))
        val over = session.alice.send("س".repeat(97)).wire
        assertEquals(2, Wire.smsParts(over))
        // The same 96 letters sent as a plain SMS would be UCS-2: two parts.
        assertEquals("س".repeat(96), session.bob.receive(fits).second)
    }

    @Test
    fun `sms parts follow the GSM-7 limits`() {
        assertEquals(1, Wire.smsParts("x".repeat(160)))
        assertEquals(2, Wire.smsParts("x".repeat(161)))
        assertEquals(2, Wire.smsParts("x".repeat(306)))
        assertEquals(3, Wire.smsParts("x".repeat(307)))
    }

    @Test
    fun `anything that is not a well-formed packet is NOT_OURS`() {
        val good = session.alice.send("سلام").wire
        val body = good.removePrefix(Wire.PREFIX)
        val bad = listOf(
            "",
            "سلام",
            "#E:",
            "#E:A",
            "#E:" + body.dropLast(1) + "=", // padding inside
            "#e:$body",
            "#E: $body",
            "$good ",
            "$good\n",
            "#E:!" + body.drop(1),
            Wire.encode(byteArrayOf(0x21, 0, 0)), // version 2
            Wire.encode(byteArrayOf(0x1F, 0, 0)), // unknown type
            Wire.encode(decodeWire(session.initWire).copyOf(500)), // truncated INIT
            Wire.encode(byteArrayOf(0x11, 0, 1, 0x80.toByte(), 0x00) + ByteArray(20)), // non-minimal counter
            Wire.encode(byteArrayOf(0x11, 0, 1, 0) + ByteArray(16)), // no payload byte
        )
        for ((i, text) in bad.withIndex()) {
            try {
                expectError(SmsCryptoException.Code.NOT_OURS) { Wire.parse(text) }
            } catch (e: AssertionError) {
                throw AssertionError("case $i: ${e.message}")
            }
        }
        // Well-formed Base64 with bytes appended still parses; the tag refuses it.
        expectError(SmsCryptoException.Code.AUTH_FAILED) { session.bob.receive(good + "AAAA") }
    }

    @Test
    fun `the counter is one byte for the first 128 messages`() {
        assertEquals(1, Wire.writeVarint(0).size)
        assertEquals(1, Wire.writeVarint(127).size)
        assertEquals(2, Wire.writeVarint(128).size)
        assertEquals(5, Wire.writeVarint(Wire.MAX_COUNTER).size)
        for (n in listOf(0L, 1L, 127L, 128L, 300L, 16_383L, 16_384L, Wire.MAX_COUNTER)) {
            val packet = byteArrayOf(0x11, 0, 7) + Wire.writeVarint(n) + ByteArray(17)
            val parsed = Wire.parse(Wire.encode(packet)) as Packet.Message
            assertEquals(n, parsed.counter)
            assertEquals(7, parsed.sid)
        }
    }

    @Test
    fun `looksEncrypted is a prefix test only`() {
        assertTrue(Wire.looksEncrypted(session.initWire))
        assertFalse(Wire.looksEncrypted("سلام #E:"))
    }
}
