package com.example.communication_super_app.smscrypto

import org.bouncycastle.util.encoders.Base64

/**
 * How an encrypted packet travels as SMS text: `#E:` followed by the packet
 * in standard Base64 without padding.
 *
 * Every character of that text is in the **GSM 03.38 basic** alphabet (`#`,
 * `:`, `A–Z a–z 0–9 + /`), so the phone's SMS stack sends it 7-bit: 160
 * characters in a single SMS and 153 per part of a long one — against 70/67
 * for anything Persian. That is why an encrypted Persian message is not
 * twice the price of a plain one. Brackets and `~` are deliberately absent:
 * they sit in GSM's *extension* table and cost two characters each.
 *
 * The first byte of every packet is `(VERSION << 4) | type`. The prefix never
 * changes; a future format bumps [VERSION], and an older build then answers
 * [SmsCryptoException.Code.NOT_OURS] for it instead of misreading it.
 */
object Wire {
    const val PREFIX = "#E:"
    const val VERSION = 1

    const val TYPE_MESSAGE = 1
    const val TYPE_INIT = 2
    const val TYPE_RESPONSE = 3

    const val SID_BYTES = 2
    const val X25519_BYTES = 32
    const val KEM_CIPHERTEXT_BYTES = 1088
    const val CONFIRM_BYTES = 16
    const val TAG_BYTES = 16

    private const val KID = PublicIdentity.KEY_ID_BYTES
    private const val HANDSHAKE_BODY = 1 + SID_BYTES + KID + KID + X25519_BYTES + KEM_CIPHERTEXT_BYTES

    /** The largest counter a message may carry; a session ends before it. */
    const val MAX_COUNTER = Int.MAX_VALUE.toLong()

    fun typeByte(type: Int): Byte = ((VERSION shl 4) or type).toByte()

    /** Cheap test for the receive path: could [text] be one of ours at all? */
    fun looksEncrypted(text: String): Boolean = text.startsWith(PREFIX)

    fun encode(packet: ByteArray): String =
        PREFIX + Base64.toBase64String(packet).trimEnd('=')

    /**
     * How many SMS parts [text] costs when every character is a single GSM-7
     * septet — which is true of everything [encode] produces.
     */
    fun smsParts(text: String): Int =
        if (text.length <= 160) 1 else (text.length + 152) / 153

    /** Parses [text]; anything that is not a well-formed packet is NOT_OURS. */
    fun parse(text: String): Packet {
        val bytes = decode(text) ?: notOurs("not an encrypted packet")
        if (bytes.isEmpty() || (bytes[0].toInt() and 0xF0) != VERSION shl 4) {
            notOurs("unknown packet version")
        }
        return when (bytes[0].toInt() and 0x0F) {
            TYPE_MESSAGE -> parseMessage(bytes)
            TYPE_INIT -> parseHandshake(bytes, TYPE_INIT)
            TYPE_RESPONSE -> parseHandshake(bytes, TYPE_RESPONSE)
            else -> notOurs("unknown packet type")
        }
    }

    private fun decode(text: String): ByteArray? {
        if (!looksEncrypted(text)) return null
        val body = text.substring(PREFIX.length)
        if (body.isEmpty() || body.length % 4 == 1) return null
        // BC's decoder skips characters outside the alphabet; checking that
        // the bytes re-encode to exactly the text refuses anything but the
        // one canonical spelling, whitespace and trailing junk included.
        val bytes = try {
            Base64.decode(body + "=".repeat((4 - body.length % 4) % 4))
        } catch (e: Exception) {
            return null
        }
        return if (Base64.toBase64String(bytes).trimEnd('=') == body) bytes else null
    }

    private fun parseMessage(bytes: ByteArray): Packet.Message {
        var at = 1
        if (bytes.size < at + SID_BYTES) notOurs("truncated message")
        val sid = readSid(bytes, at)
        at += SID_BYTES
        val (counter, length) = readVarint(bytes, at) ?: notOurs("bad message counter")
        at += length
        if (counter > MAX_COUNTER) notOurs("bad message counter")
        // The payload is at least its kind byte.
        if (bytes.size < at + 1 + TAG_BYTES) notOurs("truncated message")
        return Packet.Message(
            sid = sid,
            counter = counter,
            header = bytes.copyOfRange(0, at),
            sealed = bytes.copyOfRange(at, bytes.size),
        )
    }

    private fun parseHandshake(bytes: ByteArray, type: Int): Packet {
        val expected = if (type == TYPE_INIT) HANDSHAKE_BODY else HANDSHAKE_BODY + CONFIRM_BYTES
        if (bytes.size != expected) notOurs("handshake of the wrong size")
        var at = 1
        val sid = readSid(bytes, at)
        at += SID_BYTES
        val sender = bytes.copyOfRange(at, at + KID)
        at += KID
        val recipient = bytes.copyOfRange(at, at + KID)
        at += KID
        val ephemeral = bytes.copyOfRange(at, at + X25519_BYTES)
        at += X25519_BYTES
        val ciphertext = bytes.copyOfRange(at, at + KEM_CIPHERTEXT_BYTES)
        at += KEM_CIPHERTEXT_BYTES
        return if (type == TYPE_INIT) {
            Packet.Init(sid, sender, recipient, ephemeral, ciphertext, bytes)
        } else {
            Packet.Response(
                sid, sender, recipient, ephemeral, ciphertext,
                confirm = bytes.copyOfRange(at, at + CONFIRM_BYTES),
                bytes = bytes,
            )
        }
    }

    fun writeSid(sid: Int): ByteArray = byteArrayOf((sid ushr 8).toByte(), sid.toByte())

    private fun readSid(bytes: ByteArray, at: Int): Int =
        ((bytes[at].toInt() and 0xFF) shl 8) or (bytes[at + 1].toInt() and 0xFF)

    /** Unsigned LEB128 — one byte for the first 128 messages of a session. */
    fun writeVarint(value: Long): ByteArray {
        require(value >= 0)
        val out = ArrayList<Byte>(5)
        var v = value
        do {
            var b = (v and 0x7F).toInt()
            v = v ushr 7
            if (v != 0L) b = b or 0x80
            out.add(b.toByte())
        } while (v != 0L)
        return out.toByteArray()
    }

    /** (value, bytes read), or null for a truncated, oversized or non-minimal varint. */
    private fun readVarint(bytes: ByteArray, at: Int): Pair<Long, Int>? {
        var value = 0L
        var i = 0
        while (i < 5) {
            if (at + i >= bytes.size) return null
            val b = bytes[at + i].toInt() and 0xFF
            value = value or ((b and 0x7F).toLong() shl (7 * i))
            i++
            if (b and 0x80 == 0) {
                // A trailing zero byte is a second spelling of a shorter value.
                if (i > 1 && b == 0) return null
                return value to i
            }
        }
        return null
    }

    private fun notOurs(message: String): Nothing =
        cryptoError(SmsCryptoException.Code.NOT_OURS, message)
}

/** A parsed packet. [sid] is the session it belongs to, chosen by the initiator. */
sealed class Packet {
    abstract val sid: Int

    /** Session request: the initiator's ephemeral X25519 key and a KEM ciphertext to the responder. */
    class Init(
        override val sid: Int,
        val senderKid: ByteArray,
        val recipientKid: ByteArray,
        val ephemeral: ByteArray,
        val kemCiphertext: ByteArray,
        val bytes: ByteArray,
    ) : Packet()

    /** Session answer: the same, the other way round, plus a key confirmation. */
    class Response(
        override val sid: Int,
        val senderKid: ByteArray,
        val recipientKid: ByteArray,
        val ephemeral: ByteArray,
        val kemCiphertext: ByteArray,
        val confirm: ByteArray,
        val bytes: ByteArray,
    ) : Packet() {
        /** Everything but the confirmation — what the confirmation covers. */
        val unconfirmed: ByteArray get() = bytes.copyOf(bytes.size - Wire.CONFIRM_BYTES)
    }

    /** One message: [header] is authenticated, [sealed] is ciphertext + tag. */
    class Message(
        override val sid: Int,
        val counter: Long,
        val header: ByteArray,
        val sealed: ByteArray,
    ) : Packet()
}
