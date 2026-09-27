package com.example.communication_super_app.smscrypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class SessionTest {
    private val session = handshake(Members())

    /** Alice sends [count] numbered messages; returns her last state and the wires. */
    private fun burst(count: Int): kotlin.Pair<Session, List<String>> {
        var alice = session.alice
        val wires = (0 until count).map { i ->
            val sealed = alice.send("پیام $i")
            alice = sealed.session
            sealed.wire
        }
        return alice to wires
    }

    @Test
    fun `every message has its own key, even with the same text`() {
        val first = session.alice.send("تکراری")
        val second = first.session.send("تکراری")
        assertNotEquals(first.wire, second.wire)
        var bob = session.bob
        for (wire in listOf(first.wire, second.wire)) {
            val (next, text) = bob.receive(wire)
            assertEquals("تکراری", text)
            bob = next
        }
    }

    @Test
    fun `messages arriving out of order are all read`() {
        val (_, wires) = burst(6)
        var bob = session.bob
        for (i in listOf(3, 0, 5, 1, 4, 2)) {
            val (next, text) = bob.receive(wires[i])
            assertEquals("پیام $i", text)
            bob = next
        }
        assertEquals(0, bob.skippedCount)
        assertEquals(6L, bob.receiveCounter)
    }

    @Test
    fun `a message delivered twice is DUPLICATE the second time`() {
        val (_, wires) = burst(3)
        var bob = session.bob.receive(wires[0]).first
        bob = bob.receive(wires[2]).first // skips 1
        expectError(SmsCryptoException.Code.DUPLICATE) { bob.receive(wires[0]) }
        expectError(SmsCryptoException.Code.DUPLICATE) { bob.receive(wires[2]) }
        bob = bob.receive(wires[1]).first // the skipped one still opens, once
        expectError(SmsCryptoException.Code.DUPLICATE) { bob.receive(wires[1]) }
    }

    @Test
    fun `a counter too far ahead is refused without touching the state`() {
        val far = sealAt(session.alice, Session.MAX_SKIP + 1, "دور")
        expectError(SmsCryptoException.Code.TOO_FAR_AHEAD) { session.bob.receive(far) }
        val edge = sealAt(session.alice, Session.MAX_SKIP, "لبه")
        val (bob, text) = session.bob.receive(edge)
        assertEquals("لبه", text)
        assertEquals(Session.MAX_SKIP.toInt(), bob.skippedCount)
    }

    @Test
    fun `stored skipped keys are capped, oldest first`() {
        var bob = session.bob
        bob = bob.receive(sealAt(session.alice, Session.MAX_SKIP, "a")).first
        bob = bob.receive(sealAt(session.alice, 2 * Session.MAX_SKIP, "b")).first
        assertEquals(Session.MAX_STORED_SKIPPED, bob.skippedCount)
        // Message 0 was the oldest skipped and has been forgotten.
        expectError(SmsCryptoException.Code.DUPLICATE) { bob.receive(sealAt(session.alice, 0, "x")) }
        assertEquals("y", bob.receive(sealAt(session.alice, 2 * Session.MAX_SKIP - 1, "y")).second)
    }

    @Test
    fun `an altered message is AUTH_FAILED and the state does not move`() {
        val wire = session.alice.send("دست نخورده").wire
        val bytes = decodeWire(wire)
        for (at in 3 until bytes.size) { // past type and sid; counter, ciphertext, tag
            val altered = bytes.copyOf().also { it[at] = (it[at].toInt() xor 0x40).toByte() }
            try {
                session.bob.receive(Wire.encode(altered))
                throw AssertionError("byte $at altered and still opened")
            } catch (e: SmsCryptoException) {
                // A changed counter byte can also read as a duplicate or a far jump.
                if (e.code !in setOf(
                        SmsCryptoException.Code.AUTH_FAILED,
                        SmsCryptoException.Code.DUPLICATE,
                        SmsCryptoException.Code.TOO_FAR_AHEAD,
                        SmsCryptoException.Code.NOT_OURS,
                    )
                ) {
                    throw AssertionError("byte $at: ${e.code}")
                }
            }
        }
        assertEquals("دست نخورده", session.bob.receive(wire).second)
    }

    @Test
    fun `a message cannot be reflected back to its sender`() {
        val wire = session.alice.send("بازتاب").wire
        expectError(SmsCryptoException.Code.AUTH_FAILED) { session.alice.receive(wire) }
    }

    @Test
    fun `state survives serialization mid-conversation`() {
        val (alice, wires) = burst(4)
        var bob = session.bob.receive(wires[3]).first // three skipped keys held
        bob = Session.parse(bob.serialize())
        assertEquals(3, bob.skippedCount)
        for (i in 0..2) bob = bob.receive(wires[i]).first
        val restoredAlice = Session.parse(alice.serialize())
        assertEquals(4L, restoredAlice.sendCounter)
        assertEquals("ادامه", bob.receive(restoredAlice.send("ادامه").wire).second)
        assertArrayEquals(bob.serialize(), Session.parse(bob.serialize()).serialize())
        expectError(SmsCryptoException.Code.BAD_KEY) { Session.parse(bob.serialize().copyOf(20)) }
        expectError(SmsCryptoException.Code.BAD_KEY) { Session.parse(bob.serialize() + byteArrayOf(0)) }
    }

    @Test
    fun `a receipt travels as a control packet whose type cannot be flipped`() {
        val sealed = session.alice.seal(Payload.seen(session.alice.sid, 0), control = true)
        val packet = Wire.parse(sealed.wire) as Packet.Message
        assertEquals(true, packet.control)
        val flipped = decodeWire(sealed.wire).also { it[0] = Wire.typeByte(Wire.TYPE_MESSAGE) }
        val asMessage = Wire.parse(Wire.encode(flipped)) as Packet.Message
        assertEquals(false, asMessage.control)
        expectError(SmsCryptoException.Code.AUTH_FAILED) { session.bob.open(asMessage) }
        val opened = session.bob.open(packet)
        assertEquals(0L, (Payload.parse(opened.payload) as Payload.Seen).upTo)
        assertEquals(false, (Wire.parse(session.alice.send("x").wire) as Packet.Message).control)
    }

    @Test
    fun `plain text is NOT_OURS`() {
        expectError(SmsCryptoException.Code.NOT_OURS) { session.bob.receive("سلام") }
    }

    /** Alice's message number [counter], sealed by stepping a copy of her chain. */
    private fun sealAt(alice: Session, counter: Long, text: String): String {
        var state = alice
        var wire = ""
        for (i in 0..counter) {
            val sealed = state.send(if (i == counter) text else "")
            state = sealed.session
            wire = sealed.wire
        }
        return wire
    }
}
