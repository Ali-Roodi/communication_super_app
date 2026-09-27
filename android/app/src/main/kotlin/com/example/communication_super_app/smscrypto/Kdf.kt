package com.example.communication_super_app.smscrypto

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.HKDFParameters

/**
 * The hash-based building blocks of the SMS crypto: SHA-256, HMAC-SHA256 and
 * HKDF-SHA256 (RFC 5869). Every derivation carries its own ASCII label, so no
 * two uses of one secret can ever produce the same bytes.
 */
internal object Kdf {
    fun label(text: String): ByteArray = text.toByteArray(Charsets.US_ASCII)

    fun sha256(vararg parts: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        for (part in parts) digest.update(part)
        return digest.digest()
    }

    fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    fun hkdf(ikm: ByteArray, salt: ByteArray?, info: ByteArray, length: Int): ByteArray {
        val generator = HKDFBytesGenerator(SHA256Digest())
        generator.init(HKDFParameters(ikm, salt, info))
        return ByteArray(length).also { generator.generateBytes(it, 0, length) }
    }

    fun hkdf(ikm: ByteArray, salt: ByteArray?, info: String, length: Int): ByteArray =
        hkdf(ikm, salt, label(info), length)
}
