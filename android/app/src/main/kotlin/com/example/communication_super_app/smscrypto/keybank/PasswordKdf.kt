package com.example.communication_super_app.smscrypto.keybank

import org.bouncycastle.crypto.generators.Argon2BytesGenerator
import org.bouncycastle.crypto.params.Argon2Parameters

/**
 * Argon2id (RFC 9106): what turns something a person typed into a key.
 * Memory-hard, so a guess costs a GPU as much memory as it costs the phone.
 *
 * A key file carries its own cost in its header and may use any within
 * [MAX_*]; [KEY_FILE] is what the issuance tools write.
 */
data class PasswordKdf(val iterations: Int, val memoryKiB: Int, val parallelism: Int) {
    companion object {
        /**
         * Key files, update files and the authority file: 64 MiB, 3 passes,
         * one lane — RFC 9106's second recommended setting with one lane.
         * Paid once per import.
         */
        val KEY_FILE = PasswordKdf(iterations = 3, memoryKiB = 64 * 1024, parallelism = 1)

        /** Refused above these: a file must not be able to exhaust the phone. */
        const val MAX_ITERATIONS = 10
        const val MAX_MEMORY_KIB = 256 * 1024
        const val MAX_PARALLELISM = 4
    }

    val acceptable: Boolean
        get() = iterations in 1..MAX_ITERATIONS &&
            memoryKiB in 8 * parallelism..MAX_MEMORY_KIB &&
            parallelism in 1..MAX_PARALLELISM

    fun derive(secret: ByteArray, salt: ByteArray, length: Int = 32): ByteArray {
        require(acceptable) { "unacceptable Argon2 parameters" }
        val generator = Argon2BytesGenerator()
        generator.init(
            Argon2Parameters.Builder(Argon2Parameters.ARGON2_id)
                .withVersion(Argon2Parameters.ARGON2_VERSION_13)
                .withIterations(iterations)
                .withMemoryAsKB(memoryKiB)
                .withParallelism(parallelism)
                .withSalt(salt)
                .build(),
        )
        return ByteArray(length).also { generator.generateBytes(secret, it) }
    }
}
