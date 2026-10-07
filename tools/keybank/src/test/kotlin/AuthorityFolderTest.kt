package ir.hamrasan.keybank

import com.example.communication_super_app.smscrypto.keybank.AuthorityFile
import com.example.communication_super_app.smscrypto.keybank.AuthorityKey
import com.example.communication_super_app.smscrypto.keybank.Directory
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import com.example.communication_super_app.smscrypto.keybank.PasswordKdf
import com.example.communication_super_app.smscrypto.keybank.UpdateFile
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
        assertEquals(listOf("001-09120000002.hkb", "002-09120000001.hkb", "notes.hkb", "passwords.csv", "update.hku"), names)
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

    private fun open(f: Issuance.IssuedFile) =
        KeyFile.open(f.file.readBytes(), f.password, listOf(authority.key.public))

    private fun status(i: Int) = folder.snapshot().let { it.statusOf(it.entries[i]) }

    private fun threeMembers(): List<Issuance.IssuedFile> {
        add("علی", "09120000001", organization = "سازمان آزمون")
        add("مریم", "09120000002", "02188776655")
        return add("رضا", "09120000003")
    }

    @Test
    fun deliveriesDecideWhoHoldsAnOldFile() {
        add("علی", "09120000001", organization = "سازمان آزمون")
        add("مریم", "09120000002")
        assertEquals(AuthorityFolder.DeliveryStatus.NOT_RECORDED, status(0))
        folder.markDelivered(listOf(0, 1))
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(0))
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(1))
        assertTrue(folder.snapshot().outdated.isEmpty())

        add("رضا", "09120000003")
        assertEquals(AuthorityFolder.DeliveryStatus.STALE, status(0))
        assertEquals(AuthorityFolder.DeliveryStatus.STALE, status(1))
        assertEquals(AuthorityFolder.DeliveryStatus.NOT_RECORDED, status(2))
        assertEquals(listOf("علی", "مریم", "رضا"), folder.snapshot().outdated.map { it.name })

        folder.markDelivered(0)
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(0))
        assertEquals(AuthorityFolder.DeliveryStatus.STALE, status(1))

        val log = folder.snapshot().log
        assertEquals(
            listOf("add", "add", "delivered", "delivered", "add", "delivered"),
            log.map { it.action.code },
        )
        assertEquals("رضا", log[4].member)
        assertEquals(3, log[4].members)
    }

    @Test
    fun aNewKeyChangesOnlyThatMembersKeyAndPassword() {
        val before = threeMembers()
        val oldKeys = before.map { open(it).identity!!.public.keyId }
        folder.markDelivered(listOf(0, 1, 2))
        val issued = folder.newKey(authority, 1, random, cheap)

        val mine = open(issued[1])
        assertNotEquals(before[1].password, issued[1].password)
        assertFailsWith<Exception> { KeyFile.open(issued[1].file.readBytes(), before[1].password, listOf(authority.key.public)) }
        assertTrue(!oldKeys[1].contentEquals(mine.identity!!.public.keyId))
        for (i in listOf(0, 2)) {
            assertEquals(before[i].password, issued[i].password)
            assertContentEquals(oldKeys[i], open(issued[i]).identity!!.public.keyId)
        }
        assertEquals(1, folder.snapshot().entries[1].generation)
        assertTrue("مریم,09120000002;02188776655,1" in folder.rosterFile.readText())
        assertEquals(AuthorityFolder.DeliveryStatus.NEW_KEY, status(1))
        assertEquals(AuthorityFolder.DeliveryStatus.STALE, status(0))
        folder.markDelivered(1)
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(1))
    }

    @Test
    fun editingKeepsTheKeyUnlessTheFirstNumberChanges() {
        val before = threeMembers()
        val oldKeys = before.map { open(it).identity!!.public.keyId }
        val renamed = folder.editMember(authority, 0, "علی رودی", listOf("09120000001", "02166554433"), random, cheap)
        assertEquals("علی رودی", folder.snapshot().entries[0].name)
        assertEquals(before[0].password, renamed[0].password)
        assertContentEquals(oldKeys[0], open(renamed[0]).identity!!.public.keyId)
        assertEquals(listOf("09120000001", "02166554433"), open(renamed[0]).directory.members[0].phones)

        val moved = folder.editMember(authority, 0, "علی رودی", listOf("09129999999"), random, cheap)
        assertEquals(before[0].password, moved[0].password, "the password follows the member")
        assertTrue(!oldKeys[0].contentEquals(open(moved[0]).identity!!.public.keyId))
        assertEquals("001-09129999999.hkb", moved[0].file.name)
        assertTrue(!File(folder.issuedDir, "001-09120000001.hkb").exists())
        for (i in listOf(1, 2)) assertEquals(before[i].password, moved[i].password)

        assertFailsWith<AuthorityFolder.MemberError> { folder.prepareEdit(0, "علی رودی", listOf("09129999999")) }
        assertFailsWith<AuthorityFolder.MemberError> { folder.prepareEdit(0, "علی", listOf("09120000002")) }
        assertFailsWith<AuthorityFolder.MemberError> { folder.prepareEdit(0, "علی", listOf("02188776655")) }
        assertFailsWith<AuthorityFolder.MemberError> { folder.prepareEdit(9, "علی", listOf("09121111111")) }
        assertEquals("edit", folder.snapshot().log.last().action.code)
    }

    @Test
    fun removingAMemberDropsTheirFileAndPassword() {
        val before = threeMembers()
        val oldKeys = before.map { open(it).identity!!.public.keyId }
        val issued = folder.removeMember(authority, 0, random, cheap)
        assertEquals(listOf("مریم", "رضا"), folder.snapshot().entries.map { it.name })
        assertEquals(listOf("001-09120000002.hkb", "002-09120000003.hkb"), issued.map { it.file.name })
        assertEquals(before[1].password, issued[0].password)
        assertEquals(2, open(issued[0]).directory.members.size)
        assertTrue("09120000001" !in folder.passwordsFile.readText())
        val files = folder.issuedDir.listFiles()!!.map { it.name }.sorted()
        assertEquals(listOf("001-09120000002.hkb", "002-09120000003.hkb", "passwords.csv", "update.hku"), files)
        assertEquals("remove", folder.snapshot().log.last().action.code)
        assertEquals("علی", folder.snapshot().log.last().member)

        folder.removeMember(authority, 0, random, cheap)
        val e = assertFailsWith<AuthorityFolder.MemberError> { folder.removeMember(authority, 0, random, cheap) }
        assertTrue("آخرین" in e.message!!)
        assertEquals(1, folder.snapshot().entries.size)
    }

    @Test
    fun aRetiredKeyIsNeverIssuedAgain() {
        val before = threeMembers()
        val oldKeys = before.map { open(it).identity!!.public.keyId }
        folder.removeMember(authority, 0, random, cheap)
        val back = add("علی", "09120000001").last()
        assertEquals(1, back.entry.generation)
        assertTrue(!oldKeys[0].contentEquals(open(back).identity!!.public.keyId))
    }

    @Test
    fun aFailedIssueChangesNothing() {
        threeMembers()
        val roster = folder.rosterFile.readText()
        val files = folder.issuedDir.listFiles()!!.associate { it.name to it.readBytes() }
        assertFailsWith<IllegalStateException> {
            folder.newKey(authority, 1, random, cheap) { done, _ -> check(done < 2) { "disk full" } }
        }
        assertEquals(roster, folder.rosterFile.readText())
        val after = folder.issuedDir.listFiles()!!.associate { it.name to it.readBytes() }
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
        folder.removeMember(authority, 0, random, cheap)
        assertEquals(
            "﻿organization,سازمان نمونه\n# اعضای اصلی\nname,phones,generation\n\n# بقیه\nمریم کریمی,09120000002\n",
            folder.rosterFile.readText(),
        )
    }

    @Test
    fun everyIssueWritesTheUpdateFileForEveryone() {
        val issued = threeMembers()
        val update = UpdateFile.open(folder.updateFile.readBytes(), listOf(authority.directoryId), listOf(authority.key.public))
        assertEquals(3, update.directory.members.size)
        // The very directory the members' files carry: importing one after
        // the other never meets a "newer" copy.
        assertContentEquals(open(issued[0]).signed.encode(), update.signed.encode())
        assertEquals(null, update.identity)
    }

    @Test
    fun theUpdateFileBringsADirectoryUpToDateButNotANewKey() {
        threeMembers()
        folder.markDelivered(listOf(0, 1, 2))
        folder.newKey(authority, 2, random, cheap)
        assertEquals(AuthorityFolder.DeliveryStatus.STALE, status(0))
        folder.markUpdated(listOf(0, 1, 2))
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(0))
        assertEquals(AuthorityFolder.DeliveryStatus.CURRENT, status(1))
        assertEquals(AuthorityFolder.DeliveryStatus.NEW_KEY, status(2), "a new key comes only in their own file")
        assertEquals("update-delivered", folder.snapshot().log.last().action.code)
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
