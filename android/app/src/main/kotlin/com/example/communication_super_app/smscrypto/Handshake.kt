package com.example.communication_super_app.smscrypto

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import org.bouncycastle.crypto.kems.MLKEMExtractor
import org.bouncycastle.crypto.kems.MLKEMGenerator
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

/**
 * How two members who hold each other's [PublicIdentity] (from the key bank)
 * agree on a [Session]: one INIT, one RESPONSE, about ten SMS parts each —
 * paid once per pair, not per message.
 *
 * ```
 * A → B  INIT      sid, kid(A), kid(B), eA,  ctA = ML-KEM.Encaps(ek_B) → ssA
 * B → A  RESPONSE  sid, kid(B), kid(A), eB,  ctB = ML-KEM.Encaps(ek_A) → ssB,
 *                  confirm
 * ```
 *
 * The session key material is HKDF over
 * `ssA ‖ ssB ‖ X25519(eA, X_B) ‖ X25519(X_A, eB) ‖ X25519(eA, eB)`, salted
 * with a hash of both packets:
 *
 * - **Post-quantum and mutually authenticated**: only B can decapsulate ctA
 *   and only A can decapsulate ctB, so each side knows the key is shared with
 *   the holder of the identity it looked up — no signatures needed.
 * - **Hybrid**: the X25519 terms mean the session also stays secret if
 *   ML-KEM is ever broken classically; the ephemeral-ephemeral term gives
 *   classical forward secrecy against a later theft of both identity keys.
 * - `confirm` lets A check that B derived the same keys before A uses them
 *   (ML-KEM's implicit rejection turns a mismatch into a random key, never an
 *   error, so without it a bad RESPONSE would only surface as undecryptable
 *   messages). B learns the same from A's first message.
 *
 * What it does **not** give: post-quantum forward secrecy against the theft
 * of *both* long-term keys. That needs an ephemeral ML-KEM key in the INIT
 * and a third ciphertext in the RESPONSE — ~2.3 KB more, roughly doubling
 * the handshake's SMS cost.
 */
object Handshake {
    private val INIT_LABEL = Kdf.label("hamresan.sms.init.v1")
    private val TRANSCRIPT_LABEL = Kdf.label("hamresan.sms.transcript.v1")
    private val SESSION_INFO = Kdf.label("hamresan.sms.session.v1")
    private val CONFIRM_LABEL = Kdf.label("hamresan.sms.confirm.v1")
    private const val KEY_BYTES = 32
    private const val SID_SPACE = 1 shl (8 * Wire.SID_BYTES)

    /**
     * What the initiator keeps between sending the INIT and receiving the
     * RESPONSE. Secret (it holds the ephemeral key and the first KEM secret):
     * it belongs in the secure section, like a [Session].
     */
    class Pending internal constructor(
        val sid: Int,
        val ownKid: ByteArray,
        val peerKid: ByteArray,
        internal val ephemeral: ByteArray,
        internal val kemSecret: ByteArray,
        internal val initHash: ByteArray,
    ) {
        companion object {
            private const val FORMAT: Byte = 1
            private const val SIZE = 1 + Wire.SID_BYTES + 2 * PublicIdentity.KEY_ID_BYTES + 3 * KEY_BYTES

            fun parse(bytes: ByteArray): Pending {
                if (bytes.size != SIZE || bytes[0] != FORMAT) {
                    cryptoError(SmsCryptoException.Code.BAD_KEY, "not a pending handshake")
                }
                val buf = ByteBuffer.wrap(bytes, 1, SIZE - 1)
                fun take(n: Int) = ByteArray(n).also { buf.get(it) }
                return Pending(
                    sid = buf.short.toInt() and 0xFFFF,
                    ownKid = take(PublicIdentity.KEY_ID_BYTES),
                    peerKid = take(PublicIdentity.KEY_ID_BYTES),
                    ephemeral = take(KEY_BYTES),
                    kemSecret = take(KEY_BYTES),
                    initHash = take(KEY_BYTES),
                )
            }
        }

        fun serialize(): ByteArray =
            byteArrayOf(FORMAT) + Wire.writeSid(sid) + ownKid + peerKid + ephemeral + kemSecret + initHash
    }

    class Initiated(val pending: Pending, val wire: String)

    class Responded(val session: Session, val wire: String)

    /**
     * Starts a session with [peer]. [busySids] are the session ids already in
     * use with this peer; the new one avoids them.
     */
    fun initiate(
        own: IdentityKeyPair,
        peer: PublicIdentity,
        random: SecureRandom,
        busySids: Set<Int> = emptySet(),
    ): Initiated {
        require(busySids.size < SID_SPACE) { "no free session id" }
        var sid: Int
        do {
            sid = random.nextInt(SID_SPACE)
        } while (sid in busySids)
        val ephemeral = X25519PrivateKeyParameters(random)
        val kem = MLKEMGenerator(random).generateEncapsulated(peer.mlkem)
        val packet = byteArrayOf(Wire.typeByte(Wire.TYPE_INIT)) + Wire.writeSid(sid) +
            own.public.keyId + peer.keyId + ephemeral.generatePublicKey().encoded + kem.encapsulation
        return Initiated(
            Pending(
                sid = sid,
                ownKid = own.public.keyId,
                peerKid = peer.keyId,
                ephemeral = ephemeral.encoded,
                kemSecret = kem.secret,
                initHash = Kdf.sha256(INIT_LABEL, packet),
            ),
            Wire.encode(packet),
        )
    }

    /** Answers [init] from [peer]; the responder's session is ready at once. */
    fun respond(
        own: IdentityKeyPair,
        peer: PublicIdentity,
        init: Packet.Init,
        random: SecureRandom,
    ): Responded {
        checkKids(sender = init.senderKid, peer = peer, recipient = init.recipientKid, own = own)
        val ssA = MLKEMExtractor(own.mlkem).extractSecret(init.kemCiphertext)
        val ephemeral = X25519PrivateKeyParameters(random)
        val kem = MLKEMGenerator(random).generateEncapsulated(peer.mlkem)
        val initiatorEphemeral = x25519Public(init.ephemeral)
        val header = byteArrayOf(Wire.typeByte(Wire.TYPE_RESPONSE)) + Wire.writeSid(init.sid) +
            own.public.keyId + peer.keyId + ephemeral.generatePublicKey().encoded + kem.encapsulation
        val keys = schedule(
            initHash = Kdf.sha256(INIT_LABEL, init.bytes),
            responseHeader = header,
            ssA = ssA,
            ssB = kem.secret,
            dhInitiatorEphemeralResponderStatic = agree(own.x25519, initiatorEphemeral),
            dhInitiatorStaticResponderEphemeral = agree(ephemeral, peer.x25519),
            dhEphemeral = agree(ephemeral, initiatorEphemeral),
        )
        return Responded(
            Session.start(init.sid, own.public.keyId, peer.keyId, keys.responderToInitiator, keys.initiatorToResponder),
            Wire.encode(header + keys.confirm),
        )
    }

    /** Finishes the initiator's side with [response]; checks the confirmation. */
    fun complete(
        own: IdentityKeyPair,
        peer: PublicIdentity,
        pending: Pending,
        response: Packet.Response,
    ): Session {
        if (response.sid != pending.sid) {
            cryptoError(SmsCryptoException.Code.WRONG_SESSION, "response to another handshake")
        }
        if (!MessageDigest.isEqual(pending.peerKid, peer.keyId)) {
            cryptoError(SmsCryptoException.Code.WRONG_PEER, "pending handshake is with another peer")
        }
        if (!MessageDigest.isEqual(pending.ownKid, own.public.keyId)) {
            cryptoError(SmsCryptoException.Code.NOT_FOR_US, "pending handshake is of another identity")
        }
        checkKids(sender = response.senderKid, peer = peer, recipient = response.recipientKid, own = own)
        val ssB = MLKEMExtractor(own.mlkem).extractSecret(response.kemCiphertext)
        val ephemeral = X25519PrivateKeyParameters(pending.ephemeral)
        val responderEphemeral = x25519Public(response.ephemeral)
        val keys = schedule(
            initHash = pending.initHash,
            responseHeader = response.unconfirmed,
            ssA = pending.kemSecret,
            ssB = ssB,
            dhInitiatorEphemeralResponderStatic = agree(ephemeral, peer.x25519),
            dhInitiatorStaticResponderEphemeral = agree(own.x25519, responderEphemeral),
            dhEphemeral = agree(ephemeral, responderEphemeral),
        )
        if (!MessageDigest.isEqual(keys.confirm, response.confirm)) {
            cryptoError(SmsCryptoException.Code.AUTH_FAILED, "handshake confirmation failed")
        }
        return Session.start(pending.sid, own.public.keyId, peer.keyId, keys.initiatorToResponder, keys.responderToInitiator)
    }

    /**
     * Both sides sent an INIT before either saw the other's. Each phone
     * decides the same way, from the two key ids alone: the INIT of the
     * smaller key id is the one that goes ahead. True when **ours** does —
     * keep waiting for the RESPONSE and ignore the peer's INIT; false means
     * drop our pending handshake and answer theirs.
     */
    fun ownInitWins(ownKid: ByteArray, peerKid: ByteArray): Boolean {
        for (i in ownKid.indices) {
            val a = ownKid[i].toInt() and 0xFF
            val b = peerKid[i].toInt() and 0xFF
            if (a != b) return a < b
        }
        return true
    }

    private class Keys(
        val initiatorToResponder: ByteArray,
        val responderToInitiator: ByteArray,
        val confirm: ByteArray,
    )

    private fun schedule(
        initHash: ByteArray,
        responseHeader: ByteArray,
        ssA: ByteArray,
        ssB: ByteArray,
        dhInitiatorEphemeralResponderStatic: ByteArray,
        dhInitiatorStaticResponderEphemeral: ByteArray,
        dhEphemeral: ByteArray,
    ): Keys {
        val transcript = Kdf.sha256(TRANSCRIPT_LABEL, initHash, responseHeader)
        val ikm = ssA + ssB + dhInitiatorEphemeralResponderStatic +
            dhInitiatorStaticResponderEphemeral + dhEphemeral
        val okm = Kdf.hkdf(ikm, transcript, SESSION_INFO, 3 * KEY_BYTES)
        return Keys(
            initiatorToResponder = okm.copyOfRange(0, KEY_BYTES),
            responderToInitiator = okm.copyOfRange(KEY_BYTES, 2 * KEY_BYTES),
            confirm = Kdf.hmac(okm.copyOfRange(2 * KEY_BYTES, 3 * KEY_BYTES), CONFIRM_LABEL)
                .copyOf(Wire.CONFIRM_BYTES),
        )
    }

    private fun checkKids(sender: ByteArray, peer: PublicIdentity, recipient: ByteArray, own: IdentityKeyPair) {
        if (!MessageDigest.isEqual(sender, peer.keyId)) {
            cryptoError(SmsCryptoException.Code.WRONG_PEER, "packet is from another identity")
        }
        if (!MessageDigest.isEqual(recipient, own.public.keyId)) {
            cryptoError(SmsCryptoException.Code.NOT_FOR_US, "packet is for another identity")
        }
    }

    private fun x25519Public(bytes: ByteArray) = X25519PublicKeyParameters(bytes, 0)

    /** X25519, refusing the all-zero result of a small-order point (RFC 7748 §6.1). */
    private fun agree(secret: X25519PrivateKeyParameters, other: X25519PublicKeyParameters): ByteArray {
        val out = ByteArray(X25519PrivateKeyParameters.SECRET_SIZE)
        try {
            secret.generateSecret(other, out, 0)
        } catch (e: IllegalStateException) {
            cryptoError(SmsCryptoException.Code.BAD_KEY, "invalid X25519 key")
        }
        return out
    }
}
