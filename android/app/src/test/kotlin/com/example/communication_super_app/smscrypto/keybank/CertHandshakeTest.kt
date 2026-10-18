package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.CertHandshake
import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.Packet
import com.example.communication_super_app.smscrypto.Payload
import com.example.communication_super_app.smscrypto.Session
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.Upgrade
import com.example.communication_super_app.smscrypto.Wire
import com.example.communication_super_app.smscrypto.expectError
import com.example.communication_super_app.smscrypto.receive
import com.example.communication_super_app.smscrypto.send
import java.security.SecureRandom
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * «گواهی عضو» and the session request that carries it: two members who were
 * each given only their OWN key file — never each other's key, never an
 * update — still reach each other, in two SMS parts each way.
 */
class CertHandshakeTest {
    private val random = SecureRandom()
    private val cheap = PasswordKdf(iterations = 1, memoryKiB = 64, parallelism = 1)

    private class Org(random: SecureRandom) {
        val authority = AuthorityKey.generate(random)
        val directoryId = ByteArray(8).also(random::nextBytes)
        val anchors = listOf(authority.public)
    }

    /** One member, issued alone — as a member who joins later is. */
    private class Member(val identity: IdentityKeyPair, val cert: MemberCert)

    private fun join(org: Org, name: String, phone: String, generation: Int = 0): Member {
        val roster = Issuer.parseRoster("organization,سازمان\n$name,$phone,$generation")
        val issued = Issuer.issue(org.authority, org.directoryId, roster, 1000L, random)
        val file = KeyFile.create(issued.signed, 0 to issued.identities[0], "PW", random, cheap, issued.certs[0])
        val opened = KeyFile.open(file, "PW", org.anchors)
        return Member(opened.identity, opened.cert)
    }

    private class Talking(val alice: Session, val bob: Session, val init: String, val response: String)

    private fun talk(org: Org, a: Member, b: Member): Talking {
        val started = CertHandshake.initiate(a.cert, random)
        val answered = CertHandshake.respond(b.identity, b.cert, Wire.parse(started.wire) as Packet.Init, org.anchors, random)
        val done = CertHandshake.complete(
            a.identity, a.cert, started.pending,
            Wire.parse(answered.wire) as Packet.Response, org.anchors,
        )
        assertEquals(a.cert.phone, answered.peer.phone)
        assertEquals(b.cert.phone, done.peer.phone)
        return Talking(done.session, answered.session, started.wire, answered.wire)
    }

    // ── The certificate ─────────────────────────────────────────────────────

    @Test
    fun `a certificate is 103 bytes and verifies only as signed`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111", generation = 4)
        val bytes = ali.cert.encoded
        assertEquals(MemberCert.ENCODED_BYTES, bytes.size)
        assertEquals(103, bytes.size)
        val parsed = MemberCert.parse(bytes)
        assertEquals("09121111111", parsed.phone)
        assertEquals(4, parsed.generation)
        assertSame(org.authority.public, parsed.verify(org.anchors))
        assertNull(parsed.verify(listOf(AuthorityKey.generate(random).public)))
        assertNull(parsed.verify(emptyList()))
        // Any byte changed — the number, the generation, the key or the
        // signature — and it no longer verifies.
        for (at in listOf(3, 6, 20, 90)) {
            val altered = bytes.copyOf().also { it[at] = (it[at].toInt() xor 0x01).toByte() }
            val cert = try {
                MemberCert.parse(altered)
            } catch (e: SmsCryptoException) {
                continue
            }
            assertNull("byte $at", cert.verify(org.anchors))
        }
    }

    @Test
    fun `the certificate key id is frozen (the Dart side computes it too)`() {
        // Mirrored by `certKeyIdFor` (secure_identities.dart), which expects
        // the same value for the same key.
        val kid = MemberCert.keyIdOf(ByteArray(32) { 7 })
        assertEquals("6d0190893fd7bb4f", kid.joinToString("") { "%02x".format(it) })
    }

    @Test
    fun `only mobile numbers get a certificate, and only a well-formed one parses`() {
        assertTrue(MemberCert.canName("09121234567"))
        assertFalse(MemberCert.canName("02188776655"))
        assertFalse(MemberCert.canName("0912123456"))
        assertFalse(MemberCert.canName("00447700900123"))
        val org = Org(random)
        // A member with no mobile could never be reached: not issued at all.
        try {
            Issuer.parseRoster("organization,س\nدفتر,02188776655")
            throw AssertionError("a member with no mobile was accepted")
        } catch (e: Issuer.RosterException) {
            // expected
        }
        val issued = Issuer.issue(
            org.authority, org.directoryId,
            Issuer.parseRoster("organization,س\nمدیر,02188776656;09124444444"),
            1L, random,
        )
        // The first MOBILE number, not the first number.
        assertEquals("09124444444", issued.certs[0].phone)
        expectError(SmsCryptoException.Code.BAD_KEY) { MemberCert.parse(ByteArray(102)) }
        expectError(SmsCryptoException.Code.BAD_KEY) {
            MemberCert.parse(issued.certs[0].encoded.also { it[1] = 0xAB.toByte() })
        }
    }

    @Test
    fun `a generation the certificate cannot carry is a roster error`() {
        try {
            Issuer.parseRoster("organization,س\nعلی,09121111111,256")
            throw AssertionError("accepted generation 256")
        } catch (e: Issuer.RosterException) {
            // expected
        }
        Issuer.parseRoster("organization,س\nعلی,09121111111,255")
    }

    @Test
    fun `the key file carries the member's certificate and checks it`() {
        val org = Org(random)
        val roster = Issuer.parseRoster("organization,س\nعلی,09121111111\nمریم,09122222222")
        val issued = Issuer.issue(org.authority, org.directoryId, roster, 1L, random)
        val opened = KeyFile.open(
            KeyFile.create(issued.signed, 1 to issued.identities[1], "PW", random, cheap, issued.certs[1]),
            "PW", org.anchors,
        )
        assertArrayEquals(issued.certs[1].encoded, opened.cert.encoded)
        // Someone else's certificate in a member's file.
        expectError(SmsCryptoException.Code.BAD_BUNDLE) {
            KeyFile.open(
                KeyFile.create(issued.signed, 1 to issued.identities[1], "PW", random, cheap, issued.certs[0]),
                "PW", org.anchors,
            )
        }
        // A certificate signed by another authority.
        val other = MemberCert.issue(AuthorityKey.generate(random), "09122222222", 0, issued.identities[1])
        expectError(SmsCryptoException.Code.BAD_SIGNATURE) {
            KeyFile.open(
                KeyFile.create(issued.signed, 1 to issued.identities[1], "PW", random, cheap, other),
                "PW", org.anchors,
            )
        }
    }

    // ── The handshake ───────────────────────────────────────────────────────

    @Test
    fun `members issued apart talk at once, two SMS parts each way`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        // Maryam joins later: nobody's phone gets anything new.
        val maryam = join(org, "مریم", "09122222222")
        val t = talk(org, ali, maryam)
        assertEquals(2, Wire.smsParts(t.init))
        assertEquals(2, Wire.smsParts(t.response))
        val (bob, hello) = t.bob.receive(t.alice.send("سلام، من تازه اضافه شدم").wire)
        assertEquals("سلام، من تازه اضافه شدم", hello)
        assertEquals("خوش آمدی", t.alice.receive(bob.send("خوش آمدی").wire).second)
    }

    @Test
    fun `the responder may send first`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        val maryam = join(org, "مریم", "09122222222")
        val started = CertHandshake.initiate(ali.cert, random)
        val answered = CertHandshake.respond(maryam.identity, maryam.cert, Wire.parse(started.wire) as Packet.Init, org.anchors, random)
        val early = answered.session.send("زودتر").wire
        val done = CertHandshake.complete(ali.identity, ali.cert, started.pending, Wire.parse(answered.wire) as Packet.Response, org.anchors)
        assertEquals("زودتر", done.session.receive(early).second)
    }

    @Test
    fun `a request or answer from outside the organization is refused`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        val maryam = join(org, "مریم", "09122222222")
        val stranger = join(Org(random), "غریبه", "09129999999")
        val fromStranger = Wire.parse(CertHandshake.initiate(stranger.cert, random).wire) as Packet.Init
        expectError(SmsCryptoException.Code.UNTRUSTED) {
            CertHandshake.respond(maryam.identity, maryam.cert, fromStranger, org.anchors, random)
        }
        val started = CertHandshake.initiate(ali.cert, random)
        val strangerAnswer = CertHandshake.respond(
            stranger.identity, stranger.cert, Wire.parse(started.wire) as Packet.Init,
            org.anchors,
            random,
        )
        // (the stranger trusted us; we do not trust the stranger)
        expectError(SmsCryptoException.Code.UNTRUSTED) {
            CertHandshake.complete(ali.identity, ali.cert, started.pending, Wire.parse(strangerAnswer.wire) as Packet.Response, org.anchors)
        }
    }

    @Test
    fun `an answer with somebody else's certificate fails its confirmation`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        val maryam = join(org, "مریم", "09122222222")
        val mallory = join(org, "مهاجم", "09123333333")
        val started = CertHandshake.initiate(ali.cert, random)
        // Mallory answers with Maryam's (public) certificate but her own key.
        val forged = CertHandshake.respond(
            mallory.identity, mallory.cert, Wire.parse(started.wire) as Packet.Init, org.anchors, random,
        ).wire.let { w ->
            val p = Wire.parse(w) as Packet.Response
            val bytes = p.bytes.copyOf()
            System.arraycopy(maryam.cert.encoded, 0, bytes, 3, MemberCert.ENCODED_BYTES)
            Wire.encode(bytes)
        }
        expectError(SmsCryptoException.Code.AUTH_FAILED) {
            CertHandshake.complete(ali.identity, ali.cert, started.pending, Wire.parse(forged).let { it as Packet.Response }, org.anchors)
        }
    }

    @Test
    fun `a request from our own key is refused`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        expectError(SmsCryptoException.Code.WRONG_PEER) {
            CertHandshake.respond(ali.identity, ali.cert, Wire.parse(CertHandshake.initiate(ali.cert, random).wire) as Packet.Init, org.anchors, random)
        }
    }

    @Test
    fun `a tampered answer fails its confirmation`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        val maryam = join(org, "مریم", "09122222222")
        val started = CertHandshake.initiate(ali.cert, random)
        val answer = (Wire.parse(
            CertHandshake.respond(maryam.identity, maryam.cert, Wire.parse(started.wire) as Packet.Init, org.anchors, random).wire,
        ) as Packet.Response).bytes
        val tampered = answer.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        expectError(SmsCryptoException.Code.AUTH_FAILED) {
            CertHandshake.complete(ali.identity, ali.cert, started.pending, Wire.parse(Wire.encode(tampered)) as Packet.Response, org.anchors)
        }
    }

    @Test
    fun `the pending state survives storage`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        val started = CertHandshake.initiate(ali.cert, random, busySids = setOf(1, 2, 3))
        val bytes = started.pending.serialize()
        val copy = CertHandshake.Pending.parse(bytes)
        assertEquals(started.pending.sid, copy.sid)
        assertArrayEquals(ali.cert.keyId, copy.ownKid)
        expectError(SmsCryptoException.Code.BAD_KEY) { CertHandshake.Pending.parse(bytes.copyOf(bytes.size - 1)) }
    }

    // ── The upgrade ─────────────────────────────────────────────────────────

    @Test
    fun `the background upgrade gives both sides a new post-quantum session`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        val maryam = join(org, "مریم", "09122222222")
        val t = talk(org, ali, maryam)
        // A message on the classical session, delivered only after the switch.
        val late = t.alice.send("پیش از ارتقا")
        val offer = Upgrade.offer(late.session, ali.identity)
        assertTrue(Wire.smsParts(offer.wire) <= 11)

        val atBob = t.bob.open(Wire.parse(offer.wire) as Packet.Message)
        val key = (Payload.parse(atBob.payload) as Payload.PqOffer).encapsulationKey
        val accepted = Upgrade.accept(atBob.session, key, random, busySids = setOf(t.bob.sid))
        assertTrue(Wire.smsParts(accepted.answer.wire) <= 10)

        val atAli = late.session.open(Wire.parse(accepted.answer.wire) as Packet.Message)
        val answer = Payload.parse(atAli.payload) as Payload.PqAccept
        val aliUp = Upgrade.complete(atAli.session, ali.identity, answer.sid, answer.ciphertext)
        val bobUp = accepted.upgraded
        assertEquals(bobUp.sid, aliUp.sid)
        assertFalse(aliUp.sid == t.alice.sid)

        val (bob2, hi) = bobUp.receive(aliUp.send("بعد از ارتقا").wire)
        assertEquals("بعد از ارتقا", hi)
        assertEquals("دریافت شد", aliUp.receive(bob2.send("دریافت شد").wire).second)
        // The old session still opens what was sealed on it before.
        assertEquals("پیش از ارتقا", accepted.answer.session.receive(late.wire).second)
        // And the upgraded state survives storage, root included.
        val stored = Session.parse(aliUp.serialize())
        assertEquals("دوباره", bobUp.receive(stored.send("دوباره").wire).second)
        // «I have it», one SMS part on the new session.
        val done = stored.seal(Payload.pqDone(), control = true)
        assertEquals(1, Wire.smsParts(done.wire))
        assertSame(Payload.PqDone, Payload.parse(bobUp.open(Wire.parse(done.wire) as Packet.Message).payload))
    }

    @Test
    fun `a substituted key or ciphertext gives keys that do not match`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        val maryam = join(org, "مریم", "09122222222")
        val t = talk(org, ali, maryam)
        // Bob encapsulates to a key that is not Ali's (as if it had been substituted).
        val other = join(org, "دیگری", "09125555555").identity.public.mlkem.encoded
        val accepted = Upgrade.accept(t.bob, other, random)
        val atAli = t.alice.open(Wire.parse(accepted.answer.wire) as Packet.Message)
        val answer = Payload.parse(atAli.payload) as Payload.PqAccept
        val aliUp = Upgrade.complete(atAli.session, ali.identity, answer.sid, answer.ciphertext)
        expectError(SmsCryptoException.Code.AUTH_FAILED) { accepted.upgraded.receive(aliUp.send("x").wire) }
    }

    @Test
    fun `crossed requests are settled the same way on both phones`() {
        val org = Org(random)
        val ali = join(org, "علی", "09121111111")
        val maryam = join(org, "مریم", "09122222222")
        val aliWins = CertHandshake.ownInitWins(ali.cert.keyId, maryam.cert.keyId)
        val maryamWins = CertHandshake.ownInitWins(maryam.cert.keyId, ali.cert.keyId)
        assertTrue(aliWins != maryamWins)
    }
}
