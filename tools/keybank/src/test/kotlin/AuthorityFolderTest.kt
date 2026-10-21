package ir.hamrasan.keybank

import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
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
    private val authority = AuthorityFile.Contents(AuthorityKey.generate(random))

    @AfterTest
    fun cleanUp() {
        dir.deleteRecursively()
    }

    private fun add(name: String, vararg phones: String, organization: String? = null) =
        folder.addMember(authority, name, phones.toList(), random, organization, cheap)

    private fun open(f: Issuance.IssuedFile) =
        KeyFile.open(f.file.readBytes(), f.password, listOf(authority.key.public))

    /** Every file in `issued/`, name → bytes. */
    private fun issuedFiles() = folder.issuedDir.listFiles()!!.associate { it.name to it.readBytes() }

    private fun status(i: Int) = folder.snapshot().let { it.statusOf(it.entries[i]) }

    private fun threeMembers(): List<Issuance.IssuedFile> = listOf(
        add("علی", "09120000001", organization = "سازمان آزمون"),
        add("مریم", "09120000002", "02188776655"),
        add("رضا", "09120000003"),
    )

    @Test
    fun firstMemberNeedsTheOrganization() {
        assertFailsWith<AuthorityFolder.MemberError> { add("علی", "09120000001") }
        add("علی", "+98 912 000 0001", organization = "سازمان آزمون")
        val snapshot = folder.snapshot()
        assertEquals("سازمان آزمون", snapshot.organization)
        assertEquals(listOf("09120000001"), snapshot.entries.single().phones)
    }

    @Test
    fun addingAMemberWritesTheirFileAndTouchesNobodyElses() {
        val ali = add("علی", "09120000001", organization = "سازمان آزمون")
        val before = issuedFiles()
        val maryam = add("مریم", "۰۹۱۲۰۰۰۰۰۰۲")
        assertEquals("09120000002.hkb", maryam.file.name)
        // Ali's file is the very same bytes: nothing about Maryam is in it.
        assertContentEquals(before.getValue("09120000001.hkb"), issuedFiles().getValue("09120000001.hkb"))
        assertEquals("09120000002", open(maryam).cert.phone)
        assertNotEquals(ali.password, maryam.password)
        val s = folder.snapshot()
        assertEquals(ali.password, s.passwordOf(s.entries[0]))
        assertEquals(maryam.password, s.passwordOf(s.entries[1]))
        assertEquals(setOf("09120000001.hkb", "09120000002.hkb", "passwords.csv"), issuedFiles().keys)
    }

    @Test
    fun aKeyFileNamesNobody() {
        val ali = add("علی رضایی", "09120000001", organization = "سازمان محرمانه")
        add("مریم احمدی", "09120000002")
        val bytes = ali.file.readBytes()
        for (text in listOf("علی", "مریم", "سازمان", "09120000002")) {
            val needle = text.toByteArray(Charsets.UTF_8)
            assertTrue(bytes.toList().windowed(needle.size).none { it == needle.toList() }, text)
        }
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
    fun aFileOfSomebodyNotOnTheRosterIsRemoved() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        add("مریم", "09120000002")
        // Ali leaves the roster by hand; the next issue clears his file.
        folder.rosterFile.writeText("organization,سازمان آزمون\r\nمریم,09120000002\r\n", Charsets.UTF_8)
        val unrelated = File(folder.issuedDir, "notes.hkb").apply { writeText("x") }
        add("رضا", "09120000003")
        assertEquals(
            setOf("09120000002.hkb", "09120000003.hkb", "notes.hkb", "passwords.csv"),
            issuedFiles().keys,
        )
        assertTrue(unrelated.exists())
        assertTrue("09120000001" !in folder.passwordsFile.readText())
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
    fun deliveriesAreAboutEachMembersOwnFile() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        add("مریم", "09120000002")
        assertEquals(AuthorityFolder.DeliveryStatus.NOT_RECORDED, status(0))
        folder.markDelivered(listOf(0, 1))
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(0))
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(1))

        // A newcomer changes nothing for anybody else.
        add("رضا", "09120000003")
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(0))
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(1))
        assertEquals(AuthorityFolder.DeliveryStatus.NOT_RECORDED, status(2))
        assertEquals(listOf("رضا"), folder.snapshot().outdated.map { it.name })

        folder.markDelivered(2)
        assertTrue(folder.snapshot().outdated.isEmpty())
        val log = folder.snapshot().log
        assertEquals(
            listOf("add", "add", "delivered", "delivered", "add", "delivered"),
            log.map { it.action.code },
        )
        assertEquals("رضا", log[4].member)
        assertEquals(3, log[4].members)
    }

    @Test
    fun aNewKeyChangesOnlyThatMembersFileKeyAndPassword() {
        val before = threeMembers()
        val oldKeys = before.map { open(it).cert.keyId }
        folder.markDelivered(listOf(0, 1, 2))
        val files = issuedFiles()
        val issued = folder.newKey(authority, 1, random, cheap)

        assertNotEquals(before[1].password, issued.password)
        assertFailsWith<Exception> { KeyFile.open(issued.file.readBytes(), before[1].password, listOf(authority.key.public)) }
        assertTrue(!oldKeys[1].contentEquals(open(issued).cert.keyId))
        assertEquals(1, open(issued).cert.generation)
        for (name in listOf("09120000001.hkb", "09120000003.hkb")) {
            assertContentEquals(files.getValue(name), issuedFiles().getValue(name), name)
        }
        val s = folder.snapshot()
        assertEquals(before[0].password, s.passwordOf(s.entries[0]))
        assertEquals(issued.password, s.passwordOf(s.entries[1]))
        assertEquals(1, s.entries[1].generation)
        assertTrue("مریم,09120000002;02188776655,1" in folder.rosterFile.readText())
        assertEquals(AuthorityFolder.DeliveryStatus.NEW_KEY, status(1))
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(0))
        folder.markDelivered(1)
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(1))
    }

    @Test
    fun editingKeepsTheKeyUnlessTheFirstNumberChanges() {
        val before = threeMembers()
        val oldKeys = before.map { open(it).cert.keyId }
        val renamed = folder.editMember(authority, 0, "علی رودی", listOf("09120000001", "02166554433"), random, cheap)
        assertEquals("علی رودی", folder.snapshot().entries[0].name)
        assertEquals(before[0].password, renamed.password)
        assertContentEquals(oldKeys[0], open(renamed).cert.keyId)

        val moved = folder.editMember(authority, 0, "علی رودی", listOf("09129999999"), random, cheap)
        assertEquals(before[0].password, moved.password, "the password follows the member")
        assertTrue(!oldKeys[0].contentEquals(open(moved).cert.keyId))
        assertEquals("09129999999.hkb", moved.file.name)
        assertTrue(!File(folder.issuedDir, "09120000001.hkb").exists())
        val s = folder.snapshot()
        assertEquals(moved.password, s.passwordOf(s.entries[0]))
        assertTrue("09120000001" !in folder.passwordsFile.readText())
        for (i in listOf(1, 2)) assertEquals(before[i].password, s.passwordOf(s.entries[i]))

        assertFailsWith<AuthorityFolder.MemberError> { folder.prepareEdit(0, "علی رودی", listOf("09129999999")) }
        assertFailsWith<AuthorityFolder.MemberError> { folder.prepareEdit(0, "علی", listOf("09120000002")) }
        assertFailsWith<AuthorityFolder.MemberError> { folder.prepareEdit(0, "علی", listOf("02188776655")) }
        assertFailsWith<AuthorityFolder.MemberError> { folder.prepareEdit(9, "علی", listOf("09121111111")) }
        assertEquals("edit", folder.snapshot().log.last().action.code)
    }

    @Test
    fun removingAMemberDropsTheirFileAndPasswordOnly() {
        threeMembers()
        val files = issuedFiles()
        folder.removeMember(0)
        assertEquals(listOf("مریم", "رضا"), folder.snapshot().entries.map { it.name })
        assertEquals(setOf("09120000002.hkb", "09120000003.hkb", "passwords.csv"), issuedFiles().keys)
        for (name in listOf("09120000002.hkb", "09120000003.hkb")) {
            assertContentEquals(files.getValue(name), issuedFiles().getValue(name), name)
        }
        assertTrue("09120000001" !in folder.passwordsFile.readText())
        assertEquals("remove", folder.snapshot().log.last().action.code)
        assertEquals("علی", folder.snapshot().log.last().member)

        folder.removeMember(0)
        val e = assertFailsWith<AuthorityFolder.MemberError> { folder.removeMember(0) }
        assertTrue("آخرین" in e.message!!)
        assertEquals(1, folder.snapshot().entries.size)
    }

    @Test
    fun aRetiredKeyIsNeverIssuedAgain() {
        val before = threeMembers()
        val oldKeys = before.map { open(it).cert.keyId }
        folder.removeMember(0)
        val back = add("علی", "09120000001")
        assertEquals(1, back.entry.generation)
        assertTrue(!oldKeys[0].contentEquals(open(back).cert.keyId))
    }

    @Test
    fun aFailedIssueChangesNothing() {
        threeMembers()
        val roster = folder.rosterFile.readText()
        val files = issuedFiles()
        // Argon2 parameters the sealer refuses: the write fails half-way.
        val broken = PasswordKdf(iterations = 0, memoryKiB = 64, parallelism = 1)
        assertFailsWith<IllegalArgumentException> { folder.newKey(authority, 1, random, broken) }
        assertEquals(roster, folder.rosterFile.readText())
        val after = issuedFiles()
        assertEquals(files.keys, after.keys)
        for ((name, bytes) in files) assertContentEquals(bytes, after[name], name)
        assertEquals(3, folder.snapshot().log.size, "nothing logged")
    }

    @Test
    fun editsKeepEverythingElseInAHandWrittenRoster() {
        folder.rosterFile.writeText(
            "﻿organization,سازمان نمونه\n# اعضای اصلی\nname,phones,generation\nعلی,09120000001,2\n\n# بقیه\nمریم,09120000002\n",
            Charsets.UTF_8,
        )
        folder.editMember(authority, 1, "مریم کریمی", listOf("09120000002"), random, cheap)
        assertEquals(
            "﻿organization,سازمان نمونه\n# اعضای اصلی\nname,phones,generation\nعلی,09120000001,2\n\n# بقیه\nمریم کریمی,09120000002\n",
            folder.rosterFile.readText(),
        )
        folder.removeMember(0)
        assertEquals(
            "﻿organization,سازمان نمونه\n# اعضای اصلی\nname,phones,generation\n\n# بقیه\nمریم کریمی,09120000002\n",
            folder.rosterFile.readText(),
        )
    }

    @Test
    fun theCommandLineIssueWritesEveryMemberAndKeepsPasswords() {
        threeMembers()
        val s = folder.snapshot()
        val roster = com.example.communication_super_app.smscrypto.keybank.Issuer.parseRoster(folder.rosterFile.readText())
        val again = Issuance.issue(authority, roster, folder.issuedDir, random, cheap)
        assertEquals(3, again.size)
        for ((i, f) in again.withIndex()) {
            assertEquals(s.passwordOf(s.entries[i]), f.password)
            assertEquals(s.entries[i].phones.first(), open(f).cert.phone)
        }
    }

    @Test
    fun aDamagedLogLineIsSkipped() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        folder.log.file.appendText("this is not a log line\r\n,,,\r\n")
        add("مریم", "09120000002")
        assertEquals(listOf("add", "add"), folder.snapshot().log.map { it.action.code })
        assertEquals(listOf("a", "b,c", "d\"e", ""), IssuanceLog.splitCsv("a,\"b,c\",\"d\"\"e\","))
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
