package com.example.communication_super_app.smscrypto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What an encrypted SMS tells the user while the secure section is locked.
 * A handshake request must announce itself: it carries the sender's first
 * message, and an unannounced request left that message waiting for ever
 * (found on two phones, 1405/07/14).
 */
class SecureSmsInboxArrivalTest {
    private val members = Members()
    private val established = handshake(members)

    @Test
    fun `a handshake request is something to read`() {
        assertEquals(SecureSmsInbox.Arrival.MESSAGE, SecureSmsInbox.arrival(established.initWire))
        assertTrue(SecureSmsInbox.announces(established.initWire))
    }

    @Test
    fun `the answer to our request means our message can go`() {
        assertEquals(SecureSmsInbox.Arrival.READY_TO_SEND, SecureSmsInbox.arrival(established.responseWire))
        assertTrue(SecureSmsInbox.announces(established.responseWire))
    }

    @Test
    fun `a message is something to read`() {
        val wire = established.alice.send("سلام").wire
        assertEquals(SecureSmsInbox.Arrival.MESSAGE, SecureSmsInbox.arrival(wire))
    }

    @Test
    fun `a receipt says nothing`() {
        val receipt = established.alice.seal(Payload.seen(1, 1), control = true).wire
        assertNull(SecureSmsInbox.arrival(receipt))
        assertFalse(SecureSmsInbox.announces(receipt))
    }

    @Test
    fun `anything that is not ours says nothing`() {
        assertNull(SecureSmsInbox.arrival("سلام"))
        assertNull(SecureSmsInbox.arrival("#E:not-base64!"))
    }
}
