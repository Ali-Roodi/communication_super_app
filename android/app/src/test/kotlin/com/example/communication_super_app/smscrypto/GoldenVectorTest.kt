package com.example.communication_super_app.smscrypto

import java.security.MessageDigest
import org.bouncycastle.util.encoders.Hex
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the whole protocol, byte for byte, under a fixed random source.
 *
 * Phones in the field run different builds and must keep talking to each
 * other, so the key derivation, the packet layout and the payload encoding
 * may never change by accident. If this test fails, the format changed: that
 * needs a new [Wire.VERSION] (with older packets still readable), not a new
 * expected value here.
 */
class GoldenVectorTest {
    private fun sha(text: String) =
        Hex.toHexString(MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.US_ASCII)))

    @Test
    fun `the protocol is byte-for-byte stable`() {
        val random = FixedRandom(1405)
        val alice = IdentityKeyPair.fromSeed(ByteArray(32) { 1 })
        val bob = IdentityKeyPair.fromSeed(ByteArray(32) { 2 })
        val started = Handshake.initiate(alice, bob.public, random)
        val responded = Handshake.respond(bob, alice.public, Wire.parse(started.wire) as Packet.Init, random)
        val aliceSession = Handshake.complete(
            alice,
            bob.public,
            started.pending,
            Wire.parse(responded.wire) as Packet.Response,
        )
        val message = aliceSession.send("سلام، جلسه فردا ساعت ۱۰ است").wire

        assertEquals(GOLDEN_KID_ALICE, Hex.toHexString(alice.public.keyId))
        assertEquals(GOLDEN_KID_BOB, Hex.toHexString(bob.public.keyId))
        assertEquals(GOLDEN_INIT, sha(started.wire))
        assertEquals(GOLDEN_RESPONSE, sha(responded.wire))
        assertEquals(GOLDEN_MESSAGE, message)
        assertEquals("سلام، جلسه فردا ساعت ۱۰ است", responded.session.receive(message).second)
    }

    private companion object {
        const val GOLDEN_KID_ALICE = "559e2838b3921dbe"
        const val GOLDEN_KID_BOB = "27ecbeca742b502b"
        const val GOLDEN_INIT = "f4e37dd6fcda7b0eef26756cd432932abd4b2551747e18cd24d8e10526e54330"
        const val GOLDEN_RESPONSE = "8f1565ff661fa7f6d812ee4cc0c5537d09ae22590434a1ddb43415ab221d552d"
        const val GOLDEN_MESSAGE = "#E:EfVPANLwWegqLwhcwj75xMvt8l5JnJiYUp8epCJHFPyV5yxLMEeqNJDocOf9xtSk"
    }
}
