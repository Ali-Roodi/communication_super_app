package com.example.communication_super_app.smscrypto

import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
import com.example.communication_super_app.smscrypto.keybank.MemberCert
import java.security.MessageDigest
import org.bouncycastle.util.encoders.Hex
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the whole protocol, byte for byte, under a fixed random source: the
 * certificates, the session request and its answer ([CertHandshake]), a
 * message on that session, the post-quantum [Upgrade], and a message on the
 * upgraded session.
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
        val authority = AuthorityKey.generate(random)
        val anchors = listOf(authority.public)
        val alice = IdentityKeyPair.fromSeed(ByteArray(32) { 1 })
        val bob = IdentityKeyPair.fromSeed(ByteArray(32) { 2 })
        val aliceCert = MemberCert.issue(authority, "09120000001", 0, alice)
        val bobCert = MemberCert.issue(authority, "09120000002", 3, bob)

        val started = CertHandshake.initiate(aliceCert, random)
        val responded = CertHandshake.respond(bob, bobCert, Wire.parse(started.wire) as Packet.Init, anchors, random)
        val done = CertHandshake.complete(
            alice, aliceCert, started.pending, Wire.parse(responded.wire) as Packet.Response, anchors,
        )
        val first = done.session.send("سلام، جلسه فردا ساعت ۱۰ است")
        val (bobAfterFirst, firstText) = responded.session.receive(first.wire)

        val offer = Upgrade.offer(first.session, alice)
        val atBob = bobAfterFirst.open(Wire.parse(offer.wire) as Packet.Message)
        val offered = Payload.parse(atBob.payload) as Payload.PqOffer
        val accepted = Upgrade.accept(atBob.session, offered.encapsulationKey, random)
        val atAlice = offer.session.open(Wire.parse(accepted.answer.wire) as Packet.Message)
        val answer = Payload.parse(atAlice.payload) as Payload.PqAccept
        val aliceUpgraded = Upgrade.complete(atAlice.session, alice, answer.sid, answer.ciphertext)
        val second = aliceUpgraded.send("ارتقا انجام شد")

        assertEquals(GOLDEN_CERT_ALICE, sha(Hex.toHexString(aliceCert.encoded)))
        assertEquals(GOLDEN_KID_ALICE, Hex.toHexString(aliceCert.keyId))
        assertEquals(GOLDEN_KID_BOB, Hex.toHexString(bobCert.keyId))
        assertEquals(GOLDEN_INIT, sha(started.wire))
        assertEquals(GOLDEN_RESPONSE, sha(responded.wire))
        assertEquals(GOLDEN_MESSAGE, first.wire)
        assertEquals("سلام، جلسه فردا ساعت ۱۰ است", firstText)
        assertEquals(GOLDEN_OFFER, sha(offer.wire))
        assertEquals(GOLDEN_ACCEPT, sha(accepted.answer.wire))
        assertEquals(GOLDEN_UPGRADED_MESSAGE, second.wire)
        assertEquals("ارتقا انجام شد", accepted.upgraded.receive(second.wire).second)
    }

    private companion object {
        const val GOLDEN_CERT_ALICE = "0ae94c9bb11a6b00c5d7dedb734108e0b12cbd83dd27049d28e4c047a28c7ef2"
        const val GOLDEN_KID_ALICE = "cff5a0a2f9bf1a48"
        const val GOLDEN_KID_BOB = "93f25d81a4ba4e13"
        const val GOLDEN_INIT = "640c9381c526b7af47218ddf678246ee68d0c4bd723f929f9e8fe267ea8044e0"
        const val GOLDEN_RESPONSE = "48bc760966c2629d55b3a5a455c19385e192ef45331f5cbfaeda77532ac004e0"
        const val GOLDEN_MESSAGE = "#E:EYVVACsmdwrONv35kouv+hNaZbK6ioamtIBogDRjb9nmdrGXhRipY2LMQicQbSC2"
        const val GOLDEN_OFFER = "88364c9d1bfb3bbf3d62211fc66f505a8a7d94e921c10286930a1d1c675bcf4a"
        const val GOLDEN_ACCEPT = "7f554fe24cd9946ef47ca37c286ccfa5f299ef53f9ba08a83f99fcc5f8e4fd6f"
        const val GOLDEN_UPGRADED_MESSAGE = "#E:ERSrAOU9iVK/p+iYZrMlARAZtAQ8QOcJH88gjfVluya82i8"
    }
}
