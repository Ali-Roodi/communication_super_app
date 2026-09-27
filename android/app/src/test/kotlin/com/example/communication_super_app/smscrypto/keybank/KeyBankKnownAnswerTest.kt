package com.example.communication_super_app.smscrypto.keybank

import java.security.MessageDigest
import org.bouncycastle.crypto.generators.Argon2BytesGenerator
import org.bouncycastle.crypto.params.Argon2Parameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.MLDSAParameters
import org.bouncycastle.crypto.params.MLDSAPrivateKeyParameters
import org.bouncycastle.crypto.params.MLDSAPublicKeyParameters
import org.bouncycastle.crypto.params.ParametersWithContext
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.bouncycastle.crypto.signers.MLDSASigner
import org.bouncycastle.util.encoders.Hex
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The key bank's primitives against their published vectors: ML-DSA-65
 * (NIST ACVP, `src/test/resources/mldsa65_acvp.txt`), Ed25519 (RFC 8032) and
 * Argon2id (RFC 9106). Re-run on every Bouncy Castle upgrade.
 */
class KeyBankKnownAnswerTest {
    private val vectors: List<List<String>> =
        javaClass.classLoader!!.getResourceAsStream("mldsa65_acvp.txt")!!
            .bufferedReader().readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split(' ') }

    private fun sha256(bytes: ByteArray) =
        Hex.toHexString(MessageDigest.getInstance("SHA-256").digest(bytes))

    @Test
    fun `ML-DSA-65 key generation from a seed matches NIST`() {
        val cases = vectors.filter { it[0] == "keygen" }
        assertEquals(25, cases.size)
        for ((_, seed, pkHash, skHash) in cases) {
            val key = MLDSAPrivateKeyParameters(MLDSAParameters.ml_dsa_65, Hex.decode(seed))
            assertEquals("pk for seed $seed", pkHash, sha256(key.publicKey))
            assertEquals("sk for seed $seed", skHash, sha256(key.getParametersWithFormat(MLDSAPrivateKeyParameters.EXPANDED_KEY).encoded))
        }
    }

    @Test
    fun `ML-DSA-65 verification with a context matches NIST`() {
        val cases = vectors.filter { it[0] == "sigver" }
        assertEquals(7, cases.size)
        // A List destructures only up to five components.
        for (case in cases) {
            val (verdict, pk, message, context, signature) = case.drop(1)
            val signer = MLDSASigner()
            val key = MLDSAPublicKeyParameters(MLDSAParameters.ml_dsa_65, Hex.decode(pk))
            signer.init(false, ParametersWithContext(key, if (context == "-") ByteArray(0) else Hex.decode(context)))
            val m = if (message == "-") ByteArray(0) else Hex.decode(message)
            signer.update(m, 0, m.size)
            assertEquals(verdict, if (signer.verifySignature(Hex.decode(signature))) "pass" else "fail")
        }
    }

    @Test
    fun `Ed25519 matches RFC 8032 test vectors 1 and 2`() {
        val cases = listOf(
            listOf(
                "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
                "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
                "",
                "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
            ),
            listOf(
                "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
                "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
                "72",
                "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
            ),
        )
        for ((secret, public, message, signature) in cases) {
            val key = Ed25519PrivateKeyParameters(Hex.decode(secret), 0)
            assertEquals(public, Hex.toHexString(key.generatePublicKey().encoded))
            val signer = Ed25519Signer()
            signer.init(true, key)
            val m = Hex.decode(message)
            signer.update(m, 0, m.size)
            assertEquals(signature, Hex.toHexString(signer.generateSignature()))
        }
    }

    @Test
    fun `Argon2id matches RFC 9106 section 5_3`() {
        val generator = Argon2BytesGenerator()
        generator.init(
            Argon2Parameters.Builder(Argon2Parameters.ARGON2_id)
                .withVersion(Argon2Parameters.ARGON2_VERSION_13)
                .withIterations(3)
                .withMemoryAsKB(32)
                .withParallelism(4)
                .withSalt(ByteArray(16) { 2 })
                .withSecret(ByteArray(8) { 3 })
                .withAdditional(ByteArray(12) { 4 })
                .build(),
        )
        val tag = ByteArray(32)
        generator.generateBytes(ByteArray(32) { 1 }, tag)
        assertEquals("0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659", Hex.toHexString(tag))
    }
}
