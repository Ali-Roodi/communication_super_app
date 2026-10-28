package com.example.communication_super_app.smscrypto

import com.example.communication_super_app.smscrypto.keybank.AuthorityPublic
import com.example.communication_super_app.smscrypto.keybank.MemberCert
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

/**
 * How two members agree on a [Session]: each side sends its [MemberCert],
 * the other checks the authority's signature on it. Two SMS parts each way,
 * paid once per pair — and since nobody needs to have been given the other's
 * key beforehand, nobody's phone needs a new file when a member joins.
 *
 * ```
 * A → B  INIT      sid, cert(A), eA                         138 bytes
 * B → A  RESPONSE  sid, cert(B), eB, confirm                154 bytes
 * ```
 *
 * The session key material is HKDF over
 * `X25519(eA, eB) ‖ X25519(eA, X_B) ‖ X25519(X_A, eB)`, salted with a hash
 * of both packets — the shape of Noise's XX pattern, without encrypting the
 * certificates (the numbers in them are the SMS addresses anyway):
 *
 * - **Mutual authentication.** Only the holder of B's certified key can
 *   compute `X25519(eA, X_B)`, so `confirm` proves B to A; only the holder of
 *   A's can compute `X25519(X_A, eB)`, so A's first message proves A to B.
 * - **Forward secrecy** from the ephemeral-ephemeral term: a key stolen later
 *   does not open what was recorded before.
 * - **Not post-quantum.** Two SMS parts were chosen over the ten an
 *   ML-KEM ciphertext costs (1405/07/25). The session carries a [Session.root]
 *   for [Upgrade], which the initiator runs in the background right after: from
 *   then on the messages are post-quantum too.
 */
object CertHandshake {
    private val INIT_LABEL = Kdf.label("hamresan.sms.cert-init.v1")
    private val TRANSCRIPT_LABEL = Kdf.label("hamresan.sms.cert-transcript.v1")
    private val SESSION_INFO = Kdf.label("hamresan.sms.cert-session.v1")
    private val CONFIRM_LABEL = Kdf.label("hamresan.sms.cert-confirm.v1")
    private const val KEY_BYTES = 32
    private const val SID_SPACE = 1 shl (8 * Wire.SID_BYTES)

    /**
     * What the initiator keeps until the answer comes. Secret (the ephemeral
     * key): it belongs in the secure section, like a [Session]. The peer is
     * not in it — that is the point — so the answer may come from whoever
     * holds a certificate for the number the request went to.
     */
    class Pending internal constructor(
        val sid: Int,
        val ownKid: ByteArray,
        internal val ephemeral: ByteArray,
        internal val initHash: ByteArray,
    ) {
        companion object {
            private const val FORMAT: Byte = 2
            private const val SIZE = 1 + Wire.SID_BYTES + MemberCert.KEY_ID_BYTES + 2 * KEY_BYTES

            fun parse(bytes: ByteArray): Pending {
                if (bytes.size != SIZE || bytes[0] != FORMAT) {
                    cryptoError(SmsCryptoException.Code.BAD_KEY, "not a pending certificate handshake")
                }
                val buf = ByteBuffer.wrap(bytes, 1, SIZE - 1)
                fun take(n: Int) = ByteArray(n).also { buf.get(it) }
                return Pending(
                    sid = buf.short.toInt() and 0xFFFF,
                    ownKid = take(MemberCert.KEY_ID_BYTES),
                    ephemeral = take(KEY_BYTES),
                    initHash = take(KEY_BYTES),
                )
            }
        }

        fun serialize(): ByteArray =
            byteArrayOf(FORMAT) + Wire.writeSid(sid) + ownKid + ephemeral + initHash
    }

    class Initiated(val pending: Pending, val wire: String)

    /** The responder's session, its answer, and who asked. */
    class Responded(val session: Session, val wire: String, val peer: MemberCert)

    /** The initiator's session, and who answered. */
    class Completed(val session: Session, val peer: MemberCert)

    /** Starts a session with whoever holds the number the request goes to. */
    fun initiate(
        ownCert: MemberCert,
        random: SecureRandom,
        busySids: Set<Int> = emptySet(),
    ): Initiated {
        require(busySids.size < SID_SPACE) { "no free session id" }
        var sid: Int
        do {
            sid = random.nextInt(SID_SPACE)
        } while (sid in busySids)
        val ephemeral = X25519PrivateKeyParameters(random)
        val packet = byteArrayOf(Wire.typeByte(Wire.TYPE_INIT)) + Wire.writeSid(sid) +
            ownCert.encoded + ephemeral.generatePublicKey().encoded
        return Initiated(
            Pending(sid, ownCert.keyId, ephemeral.encoded, Kdf.sha256(INIT_LABEL, packet)),
            Wire.encode(packet),
        )
    }

    /**
     * Answers [init]; the responder's session is ready at once. UNTRUSTED when
     * the request's certificate is not signed by one of [anchors].
     */
    fun respond(
        own: IdentityKeyPair,
        ownCert: MemberCert,
        init: Packet.Init,
        anchors: List<AuthorityPublic>,
        random: SecureRandom,
    ): Responded {
        checkOwn(own, ownCert)
        val peer = trusted(init.cert, anchors)
        if (MessageDigest.isEqual(peer.x25519, ownCert.x25519)) {
            cryptoError(SmsCryptoException.Code.WRONG_PEER, "a request from our own key")
        }
        val ephemeral = X25519PrivateKeyParameters(random)
        val initiatorEphemeral = x25519Public(init.ephemeral)
        val header = byteArrayOf(Wire.typeByte(Wire.TYPE_RESPONSE)) + Wire.writeSid(init.sid) +
            ownCert.encoded + ephemeral.generatePublicKey().encoded
        val keys = schedule(
            initHash = Kdf.sha256(INIT_LABEL, init.bytes),
            responseHeader = header,
            dhEphemeral = agree(ephemeral, initiatorEphemeral),
            dhInitiatorEphemeralResponderStatic = agree(own.x25519, initiatorEphemeral),
            dhInitiatorStaticResponderEphemeral = agree(ephemeral, x25519Public(peer.x25519)),
        )
        return Responded(
            Session.start(
                init.sid, ownCert.keyId, peer.keyId,
                sendChain = keys.responderToInitiator,
                receiveChain = keys.initiatorToResponder,
                root = keys.root,
            ),
            Wire.encode(header + keys.confirm),
            peer,
        )
    }

    /** Finishes the initiator's side with [response]; checks the confirmation. */
    fun complete(
        own: IdentityKeyPair,
        ownCert: MemberCert,
        pending: Pending,
        response: Packet.Response,
        anchors: List<AuthorityPublic>,
    ): Completed {
        checkOwn(own, ownCert)
        if (response.sid != pending.sid) {
            cryptoError(SmsCryptoException.Code.WRONG_SESSION, "response to another handshake")
        }
        if (!MessageDigest.isEqual(pending.ownKid, ownCert.keyId)) {
            cryptoError(SmsCryptoException.Code.NOT_FOR_US, "pending handshake is of another identity")
        }
        val peer = trusted(response.cert, anchors)
        val ephemeral = X25519PrivateKeyParameters(pending.ephemeral)
        val responderEphemeral = x25519Public(response.ephemeral)
        val keys = schedule(
            initHash = pending.initHash,
            responseHeader = response.unconfirmed,
            dhEphemeral = agree(ephemeral, responderEphemeral),
            dhInitiatorEphemeralResponderStatic = agree(ephemeral, x25519Public(peer.x25519)),
            dhInitiatorStaticResponderEphemeral = agree(own.x25519, responderEphemeral),
        )
        if (!MessageDigest.isEqual(keys.confirm, response.confirm)) {
            cryptoError(SmsCryptoException.Code.AUTH_FAILED, "handshake confirmation failed")
        }
        return Completed(
            Session.start(
                pending.sid, ownCert.keyId, peer.keyId,
                sendChain = keys.initiatorToResponder,
                receiveChain = keys.responderToInitiator,
                root = keys.root,
            ),
            peer,
        )
    }

    /**
     * Both sides sent an INIT before either saw the other's. Each phone
     * decides the same way, from the two certificates' key ids alone: the
     * INIT of the smaller key id is the one that goes ahead. True when
     * **ours** does — keep waiting for the RESPONSE and ignore the peer's
     * INIT; false means drop our pending request and answer theirs.
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
        val root: ByteArray,
    )

    private fun schedule(
        initHash: ByteArray,
        responseHeader: ByteArray,
        dhEphemeral: ByteArray,
        dhInitiatorEphemeralResponderStatic: ByteArray,
        dhInitiatorStaticResponderEphemeral: ByteArray,
    ): Keys {
        val transcript = Kdf.sha256(TRANSCRIPT_LABEL, initHash, responseHeader)
        val ikm = dhEphemeral + dhInitiatorEphemeralResponderStatic + dhInitiatorStaticResponderEphemeral
        val okm = Kdf.hkdf(ikm, transcript, SESSION_INFO, 4 * KEY_BYTES)
        return Keys(
            initiatorToResponder = okm.copyOfRange(0, KEY_BYTES),
            responderToInitiator = okm.copyOfRange(KEY_BYTES, 2 * KEY_BYTES),
            confirm = Kdf.hmac(okm.copyOfRange(2 * KEY_BYTES, 3 * KEY_BYTES), CONFIRM_LABEL)
                .copyOf(Wire.CONFIRM_BYTES),
            root = okm.copyOfRange(3 * KEY_BYTES, 4 * KEY_BYTES),
        )
    }

    /** A certificate that parses and that one of [anchors] signed. */
    private fun trusted(bytes: ByteArray, anchors: List<AuthorityPublic>): MemberCert {
        val cert = MemberCert.parse(bytes)
        cert.verify(anchors) ?: cryptoError(SmsCryptoException.Code.UNTRUSTED, "certificate not trusted")
        return cert
    }

    private fun checkOwn(own: IdentityKeyPair, ownCert: MemberCert) {
        if (!MessageDigest.isEqual(own.public.x25519.encoded, ownCert.x25519)) {
            cryptoError(SmsCryptoException.Code.BAD_KEY, "certificate is not of this identity")
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
