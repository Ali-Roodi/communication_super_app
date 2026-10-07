package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.SmsCryptoException
import java.security.SecureRandom
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** «فایل به‌روزرسانی»: the directory alone, opened without a password. */
class UpdateFileTest {
    private val random = SecureRandom()
    private val cheap = PasswordKdf(iterations = 1, memoryKiB = 64, parallelism = 1)
    private val authority = AuthorityKey.generate(random)
    private val directoryId = ByteArray(Directory.ID_BYTES).also(random::nextBytes)
    private val anchors = listOf(authority.public)

    private fun issue(vararg names: String, serial: Long = 1000L) = Issuer.issue(
        authority,
        directoryId,
        Issuer.Roster("سازمان آزمون", names.mapIndexed { i, n -> Issuer.Entry(n, listOf("0912000000${i + 1}"), 0) }),
        serial,
        random,
    )

    private fun code(block: () -> Unit) = assertThrows(SmsCryptoException::class.java, block).code

    @Test
    fun `a phone holding the directory opens it without a password`() {
        val issued = issue("علی", "مریم")
        val file = UpdateFile.create(issued.signed, directoryId, random, cheap)
        assertTrue(UpdateFile.looksLike(file))
        val other = ByteArray(Directory.ID_BYTES).also(random::nextBytes)
        val opened = UpdateFile.open(file, listOf(other, directoryId), anchors)
        assertNull(opened.identity)
        assertNull(opened.memberIndex)
        assertEquals(2, opened.directory.members.size)
        assertEquals(1000L, opened.directory.serial)
        assertArrayEquals(issued.signed.encode(), opened.signed.encode())
    }

    @Test
    fun `it is the same directory as the members' files of that issue`() {
        val issued = issue("علی", "مریم")
        val update = UpdateFile.open(UpdateFile.create(issued.signed, directoryId, random, cheap), listOf(directoryId), anchors)
        val keyFile = KeyFile.open(
            KeyFile.create(issued.signed, 0 to issued.identities[0], "AAAA-BBBB", random, cheap),
            "aaaa bbbb",
            anchors,
        )
        assertArrayEquals(keyFile.signed.encode(), update.signed.encode())
    }

    @Test
    fun `anyone else cannot open it`() {
        val file = UpdateFile.create(issue("علی").signed, directoryId, random, cheap)
        val other = ByteArray(Directory.ID_BYTES).also(random::nextBytes)
        assertEquals(SmsCryptoException.Code.WRONG_PASSWORD, code { UpdateFile.open(file, listOf(other), anchors) })
        assertEquals(SmsCryptoException.Code.WRONG_PASSWORD, code { UpdateFile.open(file, emptyList(), anchors) })
    }

    @Test
    fun `it is verified like a key file`() {
        val file = UpdateFile.create(issue("علی").signed, directoryId, random, cheap)
        val stranger = AuthorityKey.generate(random)
        assertEquals(SmsCryptoException.Code.UNTRUSTED, code { UpdateFile.open(file, listOf(directoryId), listOf(stranger.public)) })

        // Sealed for this directory but carrying another one.
        val elsewhere = ByteArray(Directory.ID_BYTES).also(random::nextBytes)
        val foreign = Issuer.issue(authority, elsewhere, Issuer.Roster("دیگر", listOf(Issuer.Entry("x", listOf("09120000009"), 0))), 5, random)
        val swapped = UpdateFile.create(foreign.signed, directoryId, random, cheap)
        assertEquals(SmsCryptoException.Code.BAD_BUNDLE, code { UpdateFile.open(swapped, listOf(directoryId), anchors) })
    }

    @Test
    fun `a key file is not an update file, and the reverse`() {
        val issued = issue("علی")
        val keyFile = KeyFile.create(issued.signed, 0 to issued.identities[0], "AAAA", random, cheap)
        assertFalse(UpdateFile.looksLike(keyFile))
        assertEquals(SmsCryptoException.Code.NOT_A_KEY_FILE, code { UpdateFile.open(keyFile, listOf(directoryId), anchors) })
        val update = UpdateFile.create(issued.signed, directoryId, random, cheap)
        assertEquals(SmsCryptoException.Code.NOT_A_KEY_FILE, code { KeyFile.open(update, "AAAA", anchors) })
    }
}
