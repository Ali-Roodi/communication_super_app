package com.example.communication_super_app.smscrypto

import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
import com.example.communication_super_app.smscrypto.keybank.MemberCert
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * A reproducible "random" source: SHA-256 of (seed, counter). Everything the
 * protocol draws at random goes through `nextBytes`, so a fixed seed gives
 * fixed packets — which is what lets [GoldenVectorTest] pin the format.
 */
class FixedRandom(private val seed: Long) : SecureRandom() {
    private var counter = 0L

    override fun nextBytes(bytes: ByteArray) {
        var at = 0
        while (at < bytes.size) {
            val block = MessageDigest.getInstance("SHA-256").digest(
                ByteBuffer.allocate(16).putLong(seed).putLong(counter++).array(),
            )
            val n = minOf(block.size, bytes.size - at)
            System.arraycopy(block, 0, bytes, at, n)
            at += n
        }
    }
}

/** Two members of one authority, each with their key and certificate. */
class Members(random: SecureRandom = SecureRandom()) {
    val authority = AuthorityKey.generate(random)
    val anchors = listOf(authority.public)
    val alice = IdentityKeyPair.generate(random)
    val bob = IdentityKeyPair.generate(random)
    val aliceCert = MemberCert.issue(authority, "09120000001", 0, alice)
    val bobCert = MemberCert.issue(authority, "09120000002", 0, bob)
}

class Established(val alice: Session, val bob: Session, val initWire: String, val responseWire: String)

/** Alice initiates, Bob responds, Alice completes ([CertHandshake]). */
fun handshake(members: Members, random: SecureRandom = SecureRandom()): Established {
    val started = CertHandshake.initiate(members.aliceCert, random)
    val responded = CertHandshake.respond(
        members.bob, members.bobCert, Wire.parse(started.wire) as Packet.Init, members.anchors, random,
    )
    val done = CertHandshake.complete(
        members.alice,
        members.aliceCert,
        started.pending,
        Wire.parse(responded.wire) as Packet.Response,
        members.anchors,
    )
    return Established(done.session, responded.session, started.wire, responded.wire)
}

fun Session.send(text: String): Session.Sealed = seal(Payload.text(text))

/** (next state, text) */
fun Session.receive(wire: String): kotlin.Pair<Session, String> {
    val opened = open(Wire.parse(wire) as Packet.Message)
    return opened.session to (Payload.parse(opened.payload) as Payload.Text).text
}

fun expectError(code: SmsCryptoException.Code, block: () -> Unit) {
    try {
        block()
    } catch (e: SmsCryptoException) {
        if (e.code != code) throw AssertionError("expected $code, got ${e.code} (${e.message})")
        return
    }
    throw AssertionError("expected $code, nothing was thrown")
}

/** The packet bytes of a `#E:` text, for tests that take packets apart. */
fun decodeWire(wire: String): ByteArray {
    val body = wire.removePrefix(Wire.PREFIX)
    return org.bouncycastle.util.encoders.Base64.decode(body + "=".repeat((4 - body.length % 4) % 4))
}
