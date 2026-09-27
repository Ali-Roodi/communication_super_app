package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
import java.io.ByteArrayOutputStream

/**
 * The key bank's binary layout: big-endian integers, length-prefixed byte
 * strings and UTF-8 text. Signatures cover these exact bytes, so there is one
 * spelling of everything — no maps, no optional whitespace, no float.
 */
internal class BinWriter {
    private val out = ByteArrayOutputStream()

    fun u8(v: Int) = apply { require(v in 0..0xFF); out.write(v) }

    fun u16(v: Int) = apply {
        require(v in 0..0xFFFF)
        out.write(v ushr 8)
        out.write(v)
    }

    fun u32(v: Long) = apply {
        require(v in 0..0xFFFF_FFFFL)
        for (shift in 24 downTo 0 step 8) out.write((v ushr shift).toInt())
    }

    fun u64(v: Long) = apply {
        require(v >= 0)
        for (shift in 56 downTo 0 step 8) out.write((v ushr shift).toInt())
    }

    fun raw(bytes: ByteArray) = apply { out.write(bytes) }

    /** A byte string with a 16-bit length. */
    fun bytes16(bytes: ByteArray) = apply { u16(bytes.size).raw(bytes) }

    /** A byte string with a 32-bit length. */
    fun bytes32(bytes: ByteArray) = apply { u32(bytes.size.toLong()).raw(bytes) }

    fun text(value: String) = bytes16(value.toByteArray(Charsets.UTF_8))

    fun toByteArray(): ByteArray = out.toByteArray()
}

/**
 * Reads what [BinWriter] wrote. Any overrun, malformed text or leftover byte
 * is [code] — the caller says what kind of file this was supposed to be.
 */
internal class BinReader(
    private val bytes: ByteArray,
    private val code: SmsCryptoException.Code,
) {
    private var at = 0

    val remaining: Int get() = bytes.size - at

    private fun need(n: Int) {
        if (n < 0 || n > remaining) fail("truncated")
    }

    fun u8(): Int {
        need(1)
        return bytes[at++].toInt() and 0xFF
    }

    fun u16(): Int = (u8() shl 8) or u8()

    fun u32(): Long {
        var v = 0L
        repeat(4) { v = (v shl 8) or u8().toLong() }
        return v
    }

    fun u64(): Long {
        var v = 0L
        repeat(8) { v = (v shl 8) or u8().toLong() }
        if (v < 0) fail("value out of range")
        return v
    }

    fun raw(n: Int): ByteArray {
        need(n)
        return bytes.copyOfRange(at, at + n).also { at += n }
    }

    fun bytes16(): ByteArray = raw(u16())

    fun bytes32(): ByteArray {
        val n = u32()
        if (n > remaining) fail("truncated")
        return raw(n.toInt())
    }

    fun text(): String =
        com.example.communication_super_app.smscrypto.Payload.strictUtf8(bytes16())
            ?: fail("malformed text")

    /** Everything was read: trailing bytes would be a second spelling. */
    fun end() {
        if (remaining != 0) fail("trailing bytes")
    }

    fun fail(message: String): Nothing = cryptoError(code, message)
}
