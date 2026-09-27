package com.example.communication_super_app.smscrypto

import java.security.SecureRandom
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HandshakeTest {
    private companion object {
        // [type][sid ×2][sender kid ×8][recipient kid ×8]…
        const val SENDER_KID_AT = 3
        const val RECIPIENT_KID_AT = 11
    }

    private val random = SecureRandom()

    @Test
    fun `a completed handshake lets both sides talk`() {
        val session = handshake(Members())
        val (bob, hello) = session.bob.receive(session.alice.send("سلام").wire)
        assertEquals("سلام", hello)
        val (_, reply) = session.alice.receive(bob.send("علیک سلام").wire)
        assertEquals("علیک سلام", reply)
    }

    @Test
    fun `the responder can send first, before the initiator has the response`() {
        val members = Members()
        val started = Handshake.initiate(members.alice, members.bob.public, random)
        val responded = Handshake.respond(members.bob, members.alice.public, Wire.parse(started.wire) as Packet.Init, random)
        val early = responded.session.send("زودتر رسید").wire
        val alice = Handshake.complete(members.alice, members.bob.public, started.pending, Wire.parse(responded.wire) as Packet.Response)
        assertEquals("زودتر رسید", alice.receive(early).second)
    }

    @Test
    fun `the same seed gives the same identity, a different one a different identity`() {
        val seed = ByteArray(32) { it.toByte() }
        val a = IdentityKeyPair.fromSeed(seed)
        val b = IdentityKeyPair.fromSeed(seed.copyOf())
        assertArrayEquals(a.public.encoded, b.public.encoded)
        assertArrayEquals(a.serialize(), b.serialize())
        val c = IdentityKeyPair.fromSeed(ByteArray(32) { (it + 1).toByte() })
        assertFalse(a.public.keyId.contentEquals(c.public.keyId))
        assertEquals(PublicIdentity.ENCODED_BYTES, a.public.encoded.size)
        assertEquals(IdentityKeyPair.SERIALIZED_BYTES, a.serialize().size)
    }

    @Test
    fun `identity and public identity survive serialization`() {
        val identity = IdentityKeyPair.generate(random)
        val copy = IdentityKeyPair.parse(identity.serialize())
        assertArrayEquals(identity.public.encoded, copy.public.encoded)
        val public = PublicIdentity.parse(identity.public.encoded)
        assertArrayEquals(identity.public.keyId, public.keyId)
    }

    @Test
    fun `malformed keys are BAD_KEY`() {
        val identity = IdentityKeyPair.generate(random)
        expectError(SmsCryptoException.Code.BAD_KEY) { IdentityKeyPair.parse(identity.serialize().copyOf(96)) }
        expectError(SmsCryptoException.Code.BAD_KEY) {
            IdentityKeyPair.parse(identity.serialize().also { it[0] = 2 })
        }
        expectError(SmsCryptoException.Code.BAD_KEY) { IdentityKeyPair.fromSeed(ByteArray(31)) }
        expectError(SmsCryptoException.Code.BAD_KEY) { PublicIdentity.parse(identity.public.encoded.copyOf(100)) }
        expectError(SmsCryptoException.Code.BAD_KEY) {
            // A coefficient ≥ q in the first slot: fails the FIPS 203 modulus check.
            PublicIdentity.parse(identity.public.encoded.copyOf().also { it[1] = -1; it[2] = -1 })
        }
    }

    @Test
    fun `a request from somebody else is WRONG_PEER`() {
        val members = Members()
        val mallory = IdentityKeyPair.generate(random)
        val init = Handshake.initiate(mallory, members.bob.public, random).wire
        expectError(SmsCryptoException.Code.WRONG_PEER) {
            Handshake.respond(members.bob, members.alice.public, Wire.parse(init) as Packet.Init, random)
        }
    }

    @Test
    fun `a request for somebody else is NOT_FOR_US`() {
        val members = Members()
        val carol = IdentityKeyPair.generate(random)
        val init = Handshake.initiate(members.alice, carol.public, random).wire
        expectError(SmsCryptoException.Code.NOT_FOR_US) {
            Handshake.respond(members.bob, members.alice.public, Wire.parse(init) as Packet.Init, random)
        }
    }

    @Test
    fun `a man in the middle cannot answer for Bob`() {
        // Mallory intercepts Alice's request, readdresses it to himself and
        // answers as "Bob". He cannot decapsulate the ciphertext made for Bob,
        // nor compute X25519 with Bob's key, so his keys are not Alice's.
        val members = Members()
        val mallory = IdentityKeyPair.generate(random)
        val started = Handshake.initiate(members.alice, members.bob.public, random)
        val init = decodeWire(started.wire)
        System.arraycopy(mallory.public.keyId, 0, init, RECIPIENT_KID_AT, 8)
        val answer = Handshake.respond(mallory, members.alice.public, Wire.parse(Wire.encode(init)) as Packet.Init, random)
        val response = decodeWire(answer.wire)
        System.arraycopy(members.bob.public.keyId, 0, response, SENDER_KID_AT, 8)
        expectError(SmsCryptoException.Code.AUTH_FAILED) {
            Handshake.complete(members.alice, members.bob.public, started.pending, Wire.parse(Wire.encode(response)) as Packet.Response)
        }
    }

    @Test
    fun `any altered byte of the request or the response is caught`() {
        val members = Members()
        val started = Handshake.initiate(members.alice, members.bob.public, random)
        val initBytes = decodeWire(started.wire)
        // Past the type, sid and kids: the ephemeral key and the ciphertext.
        for (at in listOf(19, 40, 51, 500, initBytes.size - 1)) {
            val init = initBytes.copyOf().also { it[at] = (it[at].toInt() xor 0x01).toByte() }
            val responded = try {
                Handshake.respond(members.bob, members.alice.public, Wire.parse(Wire.encode(init)) as Packet.Init, random)
            } catch (e: SmsCryptoException) {
                continue // a broken ephemeral key may be refused outright
            }
            expectError(SmsCryptoException.Code.AUTH_FAILED) {
                Handshake.complete(members.alice, members.bob.public, started.pending, Wire.parse(responded.wire) as Packet.Response)
            }
        }
        val responded = Handshake.respond(members.bob, members.alice.public, Wire.parse(started.wire) as Packet.Init, random)
        val responseBytes = decodeWire(responded.wire)
        for (at in listOf(19, 60, 700, responseBytes.size - 17, responseBytes.size - 1)) {
            val response = responseBytes.copyOf().also { it[at] = (it[at].toInt() xor 0x01).toByte() }
            try {
                Handshake.complete(members.alice, members.bob.public, started.pending, Wire.parse(Wire.encode(response)) as Packet.Response)
                throw AssertionError("byte $at was altered and the handshake completed")
            } catch (e: SmsCryptoException) {
                assertTrue(e.code == SmsCryptoException.Code.AUTH_FAILED || e.code == SmsCryptoException.Code.BAD_KEY)
            }
        }
    }

    @Test
    fun `a response to a different handshake is WRONG_SESSION`() {
        val members = Members()
        val first = Handshake.initiate(members.alice, members.bob.public, random)
        val second = Handshake.initiate(members.alice, members.bob.public, random, busySids = setOf(first.pending.sid))
        assertNotEquals(first.pending.sid, second.pending.sid)
        val answer = Handshake.respond(members.bob, members.alice.public, Wire.parse(second.wire) as Packet.Init, random)
        expectError(SmsCryptoException.Code.WRONG_SESSION) {
            Handshake.complete(members.alice, members.bob.public, first.pending, Wire.parse(answer.wire) as Packet.Response)
        }
    }

    @Test
    fun `a pending handshake survives serialization`() {
        val members = Members()
        val started = Handshake.initiate(members.alice, members.bob.public, random)
        val stored = Handshake.Pending.parse(started.pending.serialize())
        val responded = Handshake.respond(members.bob, members.alice.public, Wire.parse(started.wire) as Packet.Init, random)
        val alice = Handshake.complete(members.alice, members.bob.public, stored, Wire.parse(responded.wire) as Packet.Response)
        assertEquals("ok", responded.session.receive(alice.send("ok").wire).second)
        expectError(SmsCryptoException.Code.BAD_KEY) { Handshake.Pending.parse(ByteArray(10)) }
    }

    @Test
    fun `crossed requests resolve the same way on both phones`() {
        repeat(50) {
            val members = Members()
            val a = members.alice.public.keyId
            val b = members.bob.public.keyId
            assertEquals(!Handshake.ownInitWins(a, b), Handshake.ownInitWins(b, a))
        }
    }

    @Test
    fun `sessions with the same pair are unrelated`() {
        val members = Members()
        val one = handshake(members)
        val two = handshake(members)
        val wire = one.alice.send("first session").wire
        // Session ids are random; on the rare collision the keys still differ.
        val expected = if (one.bob.sid == two.bob.sid) {
            SmsCryptoException.Code.AUTH_FAILED
        } else {
            SmsCryptoException.Code.WRONG_SESSION
        }
        expectError(expected) { two.bob.receive(wire) }
    }

    @Test
    fun `a handshake costs about ten SMS parts each way`() {
        val session = handshake(Members())
        assertEquals(10, Wire.smsParts(session.initWire))
        assertEquals(11, Wire.smsParts(session.responseWire))
    }
}

fun decodeWire(wire: String): ByteArray {
    val body = wire.removePrefix(Wire.PREFIX)
    return org.bouncycastle.util.encoders.Base64.decode(body + "=".repeat((4 - body.length % 4) % 4))
}
