package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.CertHandshake
import com.example.communication_super_app.smscrypto.FixedRandom
import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.Packet
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.Wire
import com.example.communication_super_app.smscrypto.expectError
import com.example.communication_super_app.smscrypto.receive
import com.example.communication_super_app.smscrypto.send
import java.security.SecureRandom
import org.bouncycastle.util.encoders.Hex
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyBankTest {
    private val random = SecureRandom()

    /** Cheap Argon2id for tests that are about the format, not the cost. */
    private val cheap = PasswordKdf(iterations = 1, memoryKiB = 64, parallelism = 1)

    // ── Canon ───────────────────────────────────────────────────────────────

    @Test
    fun `every spelling of a number is one number`() {
        for (raw in listOf("09121234567", "+989121234567", "00989121234567", "989121234567", "9121234567", "0912 123 4567", "۰۹۱۲۱۲۳۴۵۶۷", "٠٩١٢١٢٣٤٥٦٧", "+98 (912) 123-4567")) {
            assertEquals(raw, "09121234567", Canon.phone(raw))
        }
        assertEquals("02188776655", Canon.phone("+98 21 8877 6655"))
        assertEquals("00447700900123", Canon.phone("+44 7700 900123"))
        assertNull(Canon.phone("سلام"))
        assertNull(Canon.phone("123"))
    }

    @Test
    fun `a key-file password is its letters and digits`() {
        assertEquals("ABCD2345EFGH", Canon.keyFilePassword("abcd-2345 efgh"))
        assertEquals("AB12", Canon.keyFilePassword("ab-۱۲"))
    }

    @Test
    fun `canonical forms are frozen`() {
        // Keys are derived from these strings: a change here changes keys.
        assertEquals("09121234567", Canon.phone("+98 912 123 4567"))
        assertEquals("ABCD2345EFGH", Canon.keyFilePassword("abcd-2345 efgh"))
    }

    // ── Authority signatures ────────────────────────────────────────────────

    @Test
    fun `an authority signature verifies only unchanged and only with both halves`() {
        val authority = AuthorityKey.generate(random)
        val message = "directory bytes".toByteArray()
        val signature = authority.sign(message, random)
        val public = AuthorityPublic.parse(authority.public.encoded)
        assertTrue(public.verify(message, signature))
        assertFalse(public.verify("directory bytez".toByteArray(), signature))
        for (at in listOf(0, 1, 40, 64, 65, 1000, signature.size - 1)) {
            val bad = signature.copyOf().also { it[at] = (it[at].toInt() xor 1).toByte() }
            assertFalse("byte $at", public.verify(message, bad))
        }
        assertFalse(AuthorityKey.generate(random).public.verify(message, signature))
        assertEquals(AuthorityPublic.SIGNATURE_BYTES, signature.size)
        assertArrayEquals(authority.serialize(), AuthorityKey.parse(authority.serialize()).serialize())
    }

    // ── Issuing and importing ───────────────────────────────────────────────

    private class Org(random: SecureRandom) {
        val authority = AuthorityKey.generate(random)
        val directoryId = ByteArray(8).also(random::nextBytes)
        val roster = Issuer.parseRoster(
            """
            organization,سازمان آزمایشی
            name,phones,generation
            علی رضایی,09121111111;02188776655
            مریم احمدی,+989122222222
            Operator,02133334444;09123333333,2
            """.trimIndent(),
        )
    }

    private fun issue(org: Org, serial: Long = 1000L) =
        Issuer.issue(org.authority, org.directoryId, org.roster, serial, random)

    private fun keyFile(issued: Issuer.Issued, i: Int, password: String) =
        KeyFile.create(issued.signed, i to issued.identities[i], password, random, cheap, issued.certs[i])

    @Test
    fun `a member imports their key file and gets the directory, their key and their certificate`() {
        val org = Org(random)
        val issued = issue(org)
        val file = keyFile(issued, 1, "ABCD-EFGH-2345-6789-JKLM")
        val opened = KeyFile.open(file, "abcd efgh 2345 6789 jklm", listOf(org.authority.public))
        assertEquals("سازمان آزمایشی", opened.directory.name)
        assertEquals(3, opened.directory.members.size)
        assertEquals(listOf("09121111111", "02188776655"), opened.directory.members[0].phones)
        assertEquals(1, opened.memberIndex)
        assertArrayEquals(issued.identities[1].serialize(), opened.identity.serialize())
        assertArrayEquals(org.directoryId, opened.directory.directoryId)
        assertEquals(1000L, opened.directory.serial)
        assertEquals("09122222222", opened.cert.phone)
        // The member is named by the same key id in the directory and in the certificate.
        assertArrayEquals(opened.directory.members[1].keyId, opened.cert.keyId)
        assertArrayEquals(issued.identities[1].x25519Public, opened.directory.members[1].x25519)
    }

    @Test
    fun `the certificate names the first mobile, whatever comes before it`() {
        val issued = issue(Org(random))
        assertEquals("09121111111", issued.certs[0].phone)
        assertEquals("09123333333", issued.certs[2].phone)
        assertEquals(2, issued.certs[2].generation)
    }

    @Test
    fun `two members of one directory can talk`() {
        val org = Org(random)
        val issued = issue(org)
        val anchors = listOf(org.authority.public)
        val ali = KeyFile.open(keyFile(issued, 0, "PW1"), "PW1", anchors)
        val maryam = KeyFile.open(keyFile(issued, 1, "PW2"), "PW2", anchors)
        val started = CertHandshake.initiate(ali.cert, random)
        val responded = CertHandshake.respond(
            maryam.identity, maryam.cert, Wire.parse(started.wire) as Packet.Init, anchors, random,
        )
        val done = CertHandshake.complete(
            ali.identity, ali.cert, started.pending, Wire.parse(responded.wire) as Packet.Response, anchors,
        )
        // Who answered is the member the directory lists.
        assertArrayEquals(ali.directory.members[1].keyId, done.peer.keyId)
        assertEquals("جلسه ساعت ۱۰", responded.session.receive(done.session.send("جلسه ساعت ۱۰").wire).second)
    }

    @Test
    fun `re-issuing keeps every key and a new generation replaces one`() {
        val org = Org(random)
        val first = issue(org, 1000)
        val again = issue(org, 2000)
        for (i in 0..2) assertArrayEquals(first.identities[i].serialize(), again.identities[i].serialize())
        val rotated = org.authority.memberIdentity("02133334444", 3)
        assertFalse(rotated.x25519Public.contentEquals(first.identities[2].x25519Public))
    }

    @Test
    fun `wrong password, wrong authority, not a key file`() {
        val org = Org(random)
        val issued = issue(org)
        val file = keyFile(issued, 0, "RIGHT")
        val anchors = listOf(org.authority.public)
        expectError(SmsCryptoException.Code.WRONG_PASSWORD) { KeyFile.open(file, "WRONG", anchors) }
        expectError(SmsCryptoException.Code.UNTRUSTED) { KeyFile.open(file, "RIGHT", listOf(AuthorityKey.generate(random).public)) }
        expectError(SmsCryptoException.Code.UNTRUSTED) { KeyFile.open(file, "RIGHT", emptyList()) }
        expectError(SmsCryptoException.Code.NOT_A_KEY_FILE) { KeyFile.open("hello".toByteArray(), "RIGHT", anchors) }
        expectError(SmsCryptoException.Code.NOT_A_KEY_FILE) { KeyFile.open(file.copyOf(30), "RIGHT", anchors) }
        // A header asking for 4 GiB of memory is refused before anything runs.
        val greedy = file.copyOf().also { it[7] = 0x10 }
        expectError(SmsCryptoException.Code.NOT_A_KEY_FILE) { KeyFile.open(greedy, "RIGHT", anchors) }
        // Any altered byte of the sealed part fails the password check.
        for (at in listOf(40, 100, file.size - 1)) {
            val bad = file.copyOf().also { it[at] = (it[at].toInt() xor 1).toByte() }
            expectError(SmsCryptoException.Code.WRONG_PASSWORD) { KeyFile.open(bad, "RIGHT", anchors) }
        }
    }

    @Test
    fun `a directory altered after signing is refused`() {
        val org = Org(random)
        val issued = issue(org)
        // Swap in Mallory's key for member 1, keep the authority's signature.
        val mallory = IdentityKeyPair.generate(random)
        val forged = Directory(
            issued.directory.authorityId, issued.directory.directoryId, issued.directory.serial, issued.directory.name,
            issued.directory.members.mapIndexed { i, m ->
                if (i == 1) Directory.Member(m.name, m.phones, mallory.x25519Public) else m
            },
        )
        val signed = SignedDirectory(forged.encode(), issued.signed.signature)
        val file = KeyFile.create(signed, 1 to mallory, "PW", random, cheap, issued.certs[1])
        expectError(SmsCryptoException.Code.BAD_SIGNATURE) { KeyFile.open(file, "PW", listOf(org.authority.public)) }
    }

    @Test
    fun `a secret that is not the listed member's is refused`() {
        val org = Org(random)
        val issued = issue(org)
        val anchors = listOf(org.authority.public)
        val swapped = KeyFile.create(issued.signed, 0 to issued.identities[1], "PW", random, cheap, issued.certs[1])
        expectError(SmsCryptoException.Code.BAD_BUNDLE) { KeyFile.open(swapped, "PW", anchors) }
        val outOfRange = KeyFile.create(issued.signed, 7 to issued.identities[1], "PW", random, cheap, issued.certs[1])
        expectError(SmsCryptoException.Code.BAD_BUNDLE) { KeyFile.open(outOfRange, "PW", anchors) }
        // The member's key with somebody else's certificate.
        val otherCert = KeyFile.create(issued.signed, 1 to issued.identities[1], "PW", random, cheap, issued.certs[0])
        expectError(SmsCryptoException.Code.BAD_BUNDLE) { KeyFile.open(otherCert, "PW", anchors) }
    }

    @Test
    fun `the roster parser takes what a spreadsheet saves and refuses mistakes`() {
        val roster = Issuer.parseRoster("﻿سازمان,اداره، شعبه ۲\r\nنام,شماره\r\nرضا\t۰۹۱۲۴۴۴۴۴۴۴\r\n# comment\r\n\r\nسارا,9125555555 02133334444,1\r\n")
        assertEquals("اداره، شعبه ۲", roster.organization)
        assertEquals(2, roster.entries.size)
        assertEquals(listOf("09124444444"), roster.entries[0].phones)
        assertEquals(listOf("09125555555", "02133334444"), roster.entries[1].phones)
        assertEquals(1, roster.entries[1].generation)
        val org = "organization,X\n"
        val bads = listOf(
            "",
            "a",
            "رضا,09121111111", // no organization line
            org, // no members
            org + "رضا,12",
            org + "رضا,09121111111\nسارا,+989121111111",
            org + "رضا,09121111111,-1",
            org + "رضا,09121111111,256",
            org + ",09121111111",
            org + org + "رضا,09121111111",
            "organization,\nرضا,09121111111",
            org + "رضا,02188776655", // no mobile: nobody could reach them
        )
        for (bad in bads) {
            assertThrows(bad, Issuer.RosterException::class.java) { Issuer.parseRoster(bad) }
        }
    }

    @Test
    fun `passwords are 20 unambiguous characters`() {
        repeat(20) {
            val p = Issuer.password(random)
            assertTrue(p, Regex("^([2-9A-HJ-NP-Z]{4}-){4}[2-9A-HJ-NP-Z]{4}$").matches(p))
        }
    }

    @Test
    fun `the authority file needs its password`() {
        val contents = AuthorityFile.Contents(AuthorityKey.generate(random), ByteArray(8) { 7 })
        val file = AuthorityFile.create(contents, "a long passphrase", random, cheap)
        val opened = AuthorityFile.open(file, "a long passphrase")
        assertArrayEquals(contents.key.serialize(), opened.key.serialize())
        assertArrayEquals(contents.directoryId, opened.directoryId)
        expectError(SmsCryptoException.Code.WRONG_PASSWORD) { AuthorityFile.open(file, "A long passphrase") }
        expectError(SmsCryptoException.Code.NOT_A_KEY_FILE) { AuthorityFile.open(keyFile(issue(Org(random)), 0, "x"), "x") }
        assertThrows(IllegalArgumentException::class.java) { AuthorityFile.create(contents, "short", random, cheap) }
    }

    @Test
    fun `the directory format is frozen`() {
        val r = FixedRandom(1405)
        val authority = AuthorityKey.generate(r)
        val roster = Issuer.parseRoster("organization,سازمان\nعلی,09121111111\nمریم,09122222222;02188776655,1")
        val issued = Issuer.issue(authority, ByteArray(8) { 9 }, roster, 1_790_000_000_000L, r)
        assertEquals(GOLDEN_AUTHORITY_ID, Hex.toHexString(authority.public.authorityId))
        assertEquals(GOLDEN_MEMBER_KID, Hex.toHexString(issued.directory.members[1].keyId))
        assertEquals(GOLDEN_DIRECTORY_SHA, sha(issued.signed.bytes))
        assertTrue(authority.public.verify(issued.signed.bytes, issued.signed.signature))
    }

    private fun sha(b: ByteArray) =
        Hex.toHexString(java.security.MessageDigest.getInstance("SHA-256").digest(b))

    private companion object {
        const val GOLDEN_AUTHORITY_ID = "e09334807b8501e0"
        const val GOLDEN_MEMBER_KID = "72cadfdd2e2336fe"
        const val GOLDEN_DIRECTORY_SHA = "e342a8e46c1fa2f03eb1261dc9568dad7b012b06fb64e43dc2e0a734e24629b2"
    }
}
