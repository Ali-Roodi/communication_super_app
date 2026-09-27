package com.example.communication_super_app.smscrypto

import java.security.MessageDigest
import org.bouncycastle.crypto.kems.MLKEMExtractor
import org.bouncycastle.crypto.kems.MLKEMGenerator
import org.bouncycastle.crypto.params.MLKEMParameters
import org.bouncycastle.crypto.params.MLKEMPrivateKeyParameters
import org.bouncycastle.crypto.params.MLKEMPublicKeyParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.util.encoders.Hex
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Pins every primitive to its published test vectors: ML-KEM-768 to NIST's
 * ACVP vectors for FIPS 203 (`src/test/resources/mlkem768_acvp.txt`), X25519
 * to RFC 7748 and HKDF to RFC 5869. Run on every Bouncy Castle upgrade.
 */
class KnownAnswerTest {
    private val params = MLKEMParameters.ml_kem_768

    private val vectors: List<List<String>> =
        javaClass.classLoader!!.getResourceAsStream("mlkem768_acvp.txt")!!
            .bufferedReader().readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split(' ') }

    private fun of(kind: String) = vectors.filter { it[0] == kind }

    private fun sha256(bytes: ByteArray) =
        Hex.toHexString(MessageDigest.getInstance("SHA-256").digest(bytes))

    @Test
    fun `ML-KEM-768 key generation from d and z matches NIST`() {
        val cases = of("keygen")
        assertEquals(25, cases.size)
        for ((_, d, z, ekHash, dkHash) in cases) {
            val key = MLKEMPrivateKeyParameters(params, Hex.decode(d + z))
            assertEquals("ek for d=$d", ekHash, sha256(key.publicKey))
            assertEquals("dk for d=$d", dkHash, sha256(key.encoded))
        }
    }

    @Test
    fun `ML-KEM-768 encapsulation matches NIST`() {
        val cases = of("encap")
        assertEquals(8, cases.size)
        for ((_, ek, m, cHash, k) in cases) {
            val result = MLKEMGenerator.internalGenerateEncapsulated(
                MLKEMPublicKeyParameters(params, Hex.decode(ek)),
                Hex.decode(m),
            )
            assertEquals(cHash, sha256(result.encapsulation))
            assertEquals(k.lowercase(), Hex.toHexString(result.secret))
        }
    }

    @Test
    fun `ML-KEM-768 decapsulation matches NIST, implicit rejection included`() {
        val cases = of("decap")
        assertEquals(10, cases.size)
        for ((_, dk, c, k) in cases) {
            val extractor = MLKEMExtractor(MLKEMPrivateKeyParameters(params, Hex.decode(dk)))
            assertEquals(k.lowercase(), Hex.toHexString(extractor.extractSecret(Hex.decode(c))))
        }
    }

    @Test
    fun `a published key failing the FIPS 203 modulus check is refused`() {
        val cases = of("ekcheck")
        assertEquals(10, cases.size)
        val x25519 = ByteArray(32) { 9 }
        for ((_, verdict, ek) in cases) {
            val encoded = byteArrayOf(1) + Hex.decode(ek) + x25519
            if (verdict == "pass") {
                PublicIdentity.parse(encoded)
            } else {
                val e = assertThrows(SmsCryptoException::class.java) { PublicIdentity.parse(encoded) }
                assertEquals(SmsCryptoException.Code.BAD_KEY, e.code)
            }
        }
    }

    @Test
    fun `X25519 matches RFC 7748 section 6_1`() {
        val alice = X25519PrivateKeyParameters(
            Hex.decode("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"),
        )
        val bob = X25519PrivateKeyParameters(
            Hex.decode("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"),
        )
        assertEquals(
            "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a",
            Hex.toHexString(alice.generatePublicKey().encoded),
        )
        assertEquals(
            "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f",
            Hex.toHexString(bob.generatePublicKey().encoded),
        )
        val shared = ByteArray(32)
        alice.generateSecret(X25519PublicKeyParameters(bob.generatePublicKey().encoded), shared, 0)
        assertEquals(
            "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742",
            Hex.toHexString(shared),
        )
    }

    @Test
    fun `HKDF-SHA256 matches RFC 5869 test case 1`() {
        val okm = Kdf.hkdf(
            ikm = ByteArray(22) { 0x0b },
            salt = Hex.decode("000102030405060708090a0b0c"),
            info = Hex.decode("f0f1f2f3f4f5f6f7f8f9"),
            length = 42,
        )
        assertArrayEquals(
            Hex.decode(
                "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            ),
            okm,
        )
    }
}
