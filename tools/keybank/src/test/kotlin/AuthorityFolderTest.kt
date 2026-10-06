package ir.hamrasan.keybank

import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
import com.example.communication_super_app.smscrypto.keybank.Directory
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import com.example.communication_super_app.smscrypto.keybank.PasswordKdf
import java.io.File
import java.nio.file.Files
import java.security.SecureRandom
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class AuthorityFolderTest {
    private val random = SecureRandom()
    private val cheap = PasswordKdf(iterations = 1, memoryKiB = 64, parallelism = 1)
    private val dir: File = Files.createTempDirectory("authority").toFile()
    private val folder = AuthorityFolder(dir)
    private val authority = AuthorityFile.Contents(
        AuthorityKey.generate(random),
        ByteArray(Directory.ID_BYTES).also(random::nextBytes),
    )

    @AfterTest
    fun cleanUp() {
        dir.deleteRecursively()
    }

    private fun add(name: String, vararg phones: String, organization: String? = null) =
        folder.addMember(authority, name, phones.toList(), random, organization, cheap)

    @Test
    fun firstMemberNeedsTheOrganization() {
        assertFailsWith<AuthorityFolder.MemberError> { add("علی", "09120000001") }
        add("علی", "+98 912 000 0001", organization = "سازمان آزمون")
        val snapshot = folder.snapshot()
        assertEquals("سازمان آزمون", snapshot.organization)
        assertEquals(listOf("09120000001"), snapshot.entries.single().phones)
    }

    @Test
    fun addingAMemberKeepsEveryoneElsesKeyAndPassword() {
        val first = add("علی", "09120000001", organization = "سازمان آزمون").single()
        val firstKey = KeyFile.open(first.file.readBytes(), first.password, listOf(authority.key.public)).identity!!

        val issued = add("مریم", "۰۹۱۲۰۰۰۰۰۰۲")
        assertEquals(2, issued.size)
        assertEquals(first.password, issued[0].password)
        val reopened = KeyFile.open(issued[0].file.readBytes(), issued[0].password, listOf(authority.key.public))
        assertContentEquals(firstKey.public.keyId, reopened.identity!!.public.keyId)
        assertEquals(2, reopened.directory.members.size)

        val newcomer = KeyFile.open(issued[1].file.readBytes(), issued[1].password, listOf(authority.key.public))
        assertEquals(1, newcomer.memberIndex)
        assertNotEquals(issued[0].password, issued[1].password)
        assertEquals(issued[1].password, folder.snapshot().passwordOf(folder.snapshot().entries[1]))
    }

    @Test
    fun aNumberAlreadyIssuedIsRefusedAndNothingIsWritten() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        val before = folder.rosterFile.readText()
        val e = assertFailsWith<AuthorityFolder.MemberError> { add("دوباره", "+989120000001") }
        assertTrue("09120000001" in e.message!!)
        assertEquals(before, folder.rosterFile.readText())
    }

    @Test
    fun badInputIsRefused() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        assertFailsWith<AuthorityFolder.MemberError> { add("", "09120000002") }
        assertFailsWith<AuthorityFolder.MemberError> { add("a,b", "09120000002") }
        assertFailsWith<AuthorityFolder.MemberError> { add("مریم", "abc") }
        assertFailsWith<AuthorityFolder.MemberError> { add("مریم") }
        // The first number must be a mobile: encrypted SMS goes to it.
        assertFailsWith<AuthorityFolder.MemberError> { add("مریم", "02188776655") }
        assertFailsWith<AuthorityFolder.MemberError> { add("مریم", "0912000000") }
        assertEquals(1, folder.snapshot().entries.size)
    }

    @Test
    fun aFileLeftBehindByAReorderIsRemoved() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        add("مریم", "09120000002")
        // Ali leaves the roster by hand and comes back at the end.
        folder.rosterFile.writeText("organization,سازمان آزمون\r\nمریم,09120000002\r\n", Charsets.UTF_8)
        val unrelated = File(folder.issuedDir, "notes.hkb").apply { writeText("x") }
        val issued = add("علی", "09120000001")
        assertEquals(listOf("001-09120000002.hkb", "002-09120000001.hkb"), issued.map { it.file.name })
        val names = folder.issuedDir.listFiles()!!.map { it.name }.sorted()
        assertEquals(listOf("001-09120000002.hkb", "002-09120000001.hkb", "notes.hkb", "passwords.csv"), names)
        assertTrue(unrelated.exists())
    }

    @Test
    fun prepareWritesNothing() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        val before = folder.rosterFile.readText()
        val (_, text, roster) = folder.prepare("مریم", listOf("09120000002", "021 8877 6655"))
        assertEquals(2, roster.entries.size)
        assertTrue(text.endsWith("مریم,09120000002;02188776655\r\n"))
        assertEquals(before, folder.rosterFile.readText())
        assertTrue(!File(dir, AuthorityFolder.BACKUP_DIR).exists())
    }

    @Test
    fun theOldRosterIsBackedUp() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        val before = folder.rosterFile.readText()
        add("مریم", "09120000002")
        val backup = File(dir, AuthorityFolder.BACKUP_DIR).listFiles()!!.single()
        assertEquals(before, backup.readText())
    }

    @Test
    fun aRosterWrittenByHandIsKeptAsItIs() {
        folder.rosterFile.writeText("﻿organization,سازمان نمونه\nname,phones,generation\nعلی,09120000001;02188776655,1", Charsets.UTF_8)
        add("مریم", "09120000002")
        val text = folder.rosterFile.readText()
        assertTrue(text.startsWith("﻿organization,سازمان نمونه\nname,phones,generation\nعلی,09120000001;02188776655,1\r\n"))
        assertEquals(1, folder.snapshot().entries[0].generation)
    }
}
