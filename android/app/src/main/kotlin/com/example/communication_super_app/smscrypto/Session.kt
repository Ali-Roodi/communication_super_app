package com.example.communication_super_app.smscrypto

import java.nio.ByteBuffer
import java.util.TreeMap
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * An established session with one peer: two **symmetric hash ratchets**, one
 * per direction, seeded by the handshake ([Handshake]).
 *
 * Every message gets its own key. A chain key `ck` steps as
 * `mk = HMAC(ck, 0x01)`, `ck' = HMAC(ck, 0x02)`; the old `ck` is forgotten,
 * so a phone seized tomorrow cannot decrypt what it received today (forward
 * secrecy). `mk` expands to an AES-256 key and a GCM nonce, which is why a
 * packet carries no nonce of its own: a key is used for exactly one message.
 *
 * SMS arrives late, out of order and sometimes twice. A message ahead of the
 * expected counter derives and keeps the keys of the ones it skipped (at most
 * [MAX_SKIP] ahead, at most [MAX_STORED_SKIPPED] kept); a counter already used
 * is [SmsCryptoException.Code.DUPLICATE].
 *
 * Immutable: [seal] and [open] return the next state and leave this one as it
 * was, so a message that fails to verify can never advance a chain. The
 * caller stores the state it gets back — in the secure section, never in the
 * main database.
 */
class Session private constructor(
    val sid: Int,
    val ownKid: ByteArray,
    val peerKid: ByteArray,
    private val sendChain: ByteArray,
    val sendCounter: Long,
    private val receiveChain: ByteArray,
    val receiveCounter: Long,
    private val skipped: TreeMap<Long, ByteArray>,
) {
    companion object {
        private const val FORMAT: Byte = 1
        private const val CHAIN_BYTES = 32

        /** How far ahead a message may be: SMS delays, not thousands lost. */
        const val MAX_SKIP = 1000L

        /** Kept keys of skipped messages; the oldest are dropped first. */
        const val MAX_STORED_SKIPPED = 1000

        private val MESSAGE_KEY = byteArrayOf(1)
        private val NEXT_CHAIN = byteArrayOf(2)
        private val MESSAGE_KEY_INFO = Kdf.label("hamresan.sms.message.v1")
        private const val KEY_BYTES = 32
        private const val NONCE_BYTES = 12

        internal fun start(
            sid: Int,
            ownKid: ByteArray,
            peerKid: ByteArray,
            sendChain: ByteArray,
            receiveChain: ByteArray,
        ) = Session(sid, ownKid, peerKid, sendChain, 0, receiveChain, 0, TreeMap())

        fun parse(bytes: ByteArray): Session {
            try {
                val buf = ByteBuffer.wrap(bytes)
                if (buf.get() != FORMAT) badState()
                val sid = buf.short.toInt() and 0xFFFF
                val own = ByteArray(PublicIdentity.KEY_ID_BYTES).also { buf.get(it) }
                val peer = ByteArray(PublicIdentity.KEY_ID_BYTES).also { buf.get(it) }
                val send = ByteArray(CHAIN_BYTES).also { buf.get(it) }
                val sendCounter = buf.long
                val receive = ByteArray(CHAIN_BYTES).also { buf.get(it) }
                val receiveCounter = buf.long
                val count = buf.short.toInt() and 0xFFFF
                if (count > MAX_STORED_SKIPPED) badState()
                val skipped = TreeMap<Long, ByteArray>()
                repeat(count) {
                    val n = buf.long
                    skipped[n] = ByteArray(CHAIN_BYTES).also { buf.get(it) }
                }
                if (buf.hasRemaining() || sendCounter < 0 || receiveCounter < 0) badState()
                return Session(sid, own, peer, send, sendCounter, receive, receiveCounter, skipped)
            } catch (e: java.nio.BufferUnderflowException) {
                badState()
            }
        }

        private fun badState(): Nothing =
            cryptoError(SmsCryptoException.Code.BAD_KEY, "not a session state")

        /** (message key, next chain key) */
        private fun step(chain: ByteArray): Pair<ByteArray, ByteArray> =
            Kdf.hmac(chain, MESSAGE_KEY) to Kdf.hmac(chain, NEXT_CHAIN)

        private fun cipher(mode: Int, messageKey: ByteArray, header: ByteArray): Cipher {
            val keyAndNonce = Kdf.hkdf(messageKey, null, MESSAGE_KEY_INFO, KEY_BYTES + NONCE_BYTES)
            return Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(
                    mode,
                    SecretKeySpec(keyAndNonce, 0, KEY_BYTES, "AES"),
                    GCMParameterSpec(Wire.TAG_BYTES * 8, keyAndNonce, KEY_BYTES, NONCE_BYTES),
                )
                updateAAD(header)
            }
        }
    }

    class Sealed(val session: Session, val wire: String)

    class Opened(val session: Session, val payload: ByteArray)

    /** Encrypts [payload] as the next message of this session. */
    fun seal(payload: ByteArray): Sealed {
        if (sendCounter > Wire.MAX_COUNTER) {
            cryptoError(SmsCryptoException.Code.REKEY_REQUIRED, "send counter exhausted")
        }
        val (messageKey, next) = step(sendChain)
        val header = byteArrayOf(Wire.typeByte(Wire.TYPE_MESSAGE)) +
            Wire.writeSid(sid) + Wire.writeVarint(sendCounter)
        val sealed = cipher(Cipher.ENCRYPT_MODE, messageKey, header).doFinal(payload)
        return Sealed(
            Session(sid, ownKid, peerKid, next, sendCounter + 1, receiveChain, receiveCounter, skipped),
            Wire.encode(header + sealed),
        )
    }

    /** Decrypts [packet], which must belong to this session. */
    fun open(packet: Packet.Message): Opened {
        if (packet.sid != sid) {
            cryptoError(SmsCryptoException.Code.WRONG_SESSION, "message of another session")
        }
        val n = packet.counter
        if (n < receiveCounter) {
            val key = skipped[n]
                ?: cryptoError(SmsCryptoException.Code.DUPLICATE, "message already received")
            val payload = decrypt(key, packet)
            val remaining = TreeMap(skipped).apply { remove(n) }
            return Opened(
                Session(sid, ownKid, peerKid, sendChain, sendCounter, receiveChain, receiveCounter, remaining),
                payload,
            )
        }
        if (n - receiveCounter > MAX_SKIP) {
            cryptoError(SmsCryptoException.Code.TOO_FAR_AHEAD, "message too far ahead")
        }
        val kept = TreeMap(skipped)
        var chain = receiveChain
        for (i in receiveCounter until n) {
            val (key, next) = step(chain)
            kept[i] = key
            chain = next
        }
        val (key, next) = step(chain)
        val payload = decrypt(key, packet)
        while (kept.size > MAX_STORED_SKIPPED) kept.pollFirstEntry()
        return Opened(
            Session(sid, ownKid, peerKid, sendChain, sendCounter, next, n + 1, kept),
            payload,
        )
    }

    private fun decrypt(messageKey: ByteArray, packet: Packet.Message): ByteArray =
        try {
            cipher(Cipher.DECRYPT_MODE, messageKey, packet.header).doFinal(packet.sealed)
        } catch (e: AEADBadTagException) {
            cryptoError(SmsCryptoException.Code.AUTH_FAILED, "message failed authentication")
        }

    /** Keys of skipped messages still held — for tests and diagnostics. */
    val skippedCount: Int get() = skipped.size

    fun serialize(): ByteArray {
        val size = 1 + Wire.SID_BYTES + 2 * PublicIdentity.KEY_ID_BYTES +
            2 * (CHAIN_BYTES + 8) + 2 + skipped.size * (8 + CHAIN_BYTES)
        val buf = ByteBuffer.allocate(size)
            .put(FORMAT)
            .putShort(sid.toShort())
            .put(ownKid)
            .put(peerKid)
            .put(sendChain)
            .putLong(sendCounter)
            .put(receiveChain)
            .putLong(receiveCounter)
            .putShort(skipped.size.toShort())
        for ((n, key) in skipped) buf.putLong(n).put(key)
        return buf.array()
    }
}
