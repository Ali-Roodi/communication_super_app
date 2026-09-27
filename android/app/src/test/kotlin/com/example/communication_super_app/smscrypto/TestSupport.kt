package com.example.communication_super_app.smscrypto

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

/** Two members who hold each other's public identity, as after a key bank import. */
class Members(random: SecureRandom = SecureRandom()) {
    val alice = IdentityKeyPair.generate(random)
    val bob = IdentityKeyPair.generate(random)
}

class Established(val alice: Session, val bob: Session, val initWire: String, val responseWire: String)

/** Alice initiates, Bob responds, Alice completes. */
fun handshake(members: Members, random: SecureRandom = SecureRandom()): Established {
    val started = Handshake.initiate(members.alice, members.bob.public, random)
    val responded = Handshake.respond(members.bob, members.alice.public, Wire.parse(started.wire) as Packet.Init, random)
    val alice = Handshake.complete(
        members.alice,
        members.bob.public,
        started.pending,
        Wire.parse(responded.wire) as Packet.Response,
    )
    return Established(alice, responded.session, started.wire, responded.wire)
}

fun Session.send(text: String): Session.Sealed = seal(Payload.text(text))

/** (next state, text) */
fun Session.receive(wire: String): kotlin.Pair<Session, String> {
    val opened = open(Wire.parse(wire) as Packet.Message)
    return opened.session to Payload.parse(opened.payload).text
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
