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

    @Test
    fun `an authority key survives storage`() {
        val authority = AuthorityKey.generate(random)
        assertArrayEquals(authority.serialize(), AuthorityKey.parse(authority.serialize()).serialize())
        assertArrayEquals(authority.public.encoded, AuthorityPublic.parse(authority.public.encoded).encoded)
    }

    // ── Issuing and importing ───────────────────────────────────────────────

    private class Org(random: SecureRandom) {
        val authority = AuthorityKey.generate(random)
        val anchors = listOf(authority.public)
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

    private fun keyFile(org: Org, i: Int, password: String): ByteArray {
        val issued = Issuer.issue(org.authority, org.roster.entries[i])
        return KeyFile.create(issued.identity, issued.cert, password, random, cheap)
    }

    /** A key file sealed by hand, for what [KeyFile.create] refuses to write. */
    private fun forged(identity: IdentityKeyPair, cert: MemberCert, password: String): ByteArray =
        SealedFile.seal(
            KeyFile.MAGIC,
            BinWriter().u8(1).bytes16(identity.serialize()).bytes16(cert.encoded).toByteArray(),
            Canon.keyFilePassword(password).toByteArray(Charsets.US_ASCII),
            random,
            cheap,
        )

    @Test
    fun `a member imports their own key and certificate and nothing else`() {
        val org = Org(random)
        val issued = Issuer.issue(org.authority, org.roster.entries[1])
        val file = KeyFile.create(issued.identity, issued.cert, "ABCD-EFGH-2345-6789-JKLM", random, cheap)
        val opened = KeyFile.open(file, "abcd efgh 2345 6789 jklm", org.anchors)
        assertArrayEquals(issued.identity.serialize(), opened.identity.serialize())
        assertEquals("09122222222", opened.cert.phone)
        assertEquals(0, opened.cert.generation)
        assertArrayEquals(org.authority.public.authorityId, opened.authority.authorityId)
        // No name — of the member, a colleague or the organization — is in the file.
        val plain = SealedFile.open(KeyFile.MAGIC, file, "ABCDEFGH23456789JKLM".toByteArray(Charsets.US_ASCII))
        val text = String(plain, Charsets.UTF_8)
        for (name in listOf("مریم", "علی", "سازمان", "Operator")) assertFalse(name, name in text)
        assertEquals(1 + 2 + IdentityKeyPair.SERIALIZED_BYTES + 2 + MemberCert.ENCODED_BYTES, plain.size)
    }

    @Test
    fun `the certificate names the first mobile, whatever comes before it`() {
        val org = Org(random)
        assertEquals("09121111111", Issuer.issue(org.authority, org.roster.entries[0]).cert.phone)
        val operator = Issuer.issue(org.authority, org.roster.entries[2]).cert
        assertEquals("09123333333", operator.phone)
        assertEquals(2, operator.generation)
    }

    @Test
    fun `two members issued apart can talk`() {
        val org = Org(random)
        val ali = KeyFile.open(keyFile(org, 0, "PW1"), "PW1", org.anchors)
        val maryam = KeyFile.open(keyFile(org, 1, "PW2"), "PW2", org.anchors)
        val started = CertHandshake.initiate(ali.cert, random)
        val responded = CertHandshake.respond(
            maryam.identity, maryam.cert, Wire.parse(started.wire) as Packet.Init, org.anchors, random,
        )
        val done = CertHandshake.complete(
            ali.identity, ali.cert, started.pending, Wire.parse(responded.wire) as Packet.Response, org.anchors,
        )
        // Who answered is known from their certificate alone.
        assertEquals("09122222222", done.peer.phone)
        assertArrayEquals(maryam.cert.keyId, done.peer.keyId)
        assertEquals("جلسه ساعت ۱۰", responded.session.receive(done.session.send("جلسه ساعت ۱۰").wire).second)
    }

    @Test
    fun `issuing again gives the same key and a new generation a new one`() {
        val org = Org(random)
        val entry = org.roster.entries[2]
        val first = Issuer.issue(org.authority, entry)
        val again = Issuer.issue(org.authority, entry)
        assertArrayEquals(first.identity.serialize(), again.identity.serialize())
        val rotated = Issuer.issue(org.authority, Issuer.Entry(entry.name, entry.phones, entry.generation + 1))
        assertFalse(rotated.identity.x25519Public.contentEquals(first.identity.x25519Public))
        assertEquals(3, rotated.cert.generation)
    }

    @Test
    fun `wrong password, untrusted authority, not a key file`() {
        val org = Org(random)
        val file = keyFile(org, 0, "RIGHT")
        expectError(SmsCryptoException.Code.WRONG_PASSWORD) { KeyFile.open(file, "WRONG", org.anchors) }
        expectError(SmsCryptoException.Code.UNTRUSTED) { KeyFile.open(file, "RIGHT", listOf(AuthorityKey.generate(random).public)) }
        expectError(SmsCryptoException.Code.UNTRUSTED) { KeyFile.open(file, "RIGHT", emptyList()) }
        expectError(SmsCryptoException.Code.NOT_A_KEY_FILE) { KeyFile.open("hello".toByteArray(), "RIGHT", org.anchors) }
        expectError(SmsCryptoException.Code.NOT_A_KEY_FILE) { KeyFile.open(file.copyOf(30), "RIGHT", org.anchors) }
        // A header asking for 4 GiB of memory is refused before anything runs.
        val greedy = file.copyOf().also { it[7] = 0x10 }
        expectError(SmsCryptoException.Code.NOT_A_KEY_FILE) { KeyFile.open(greedy, "RIGHT", org.anchors) }
        // Any altered byte of the sealed part fails the password check.
        for (at in listOf(40, 100, file.size - 1)) {
            val bad = file.copyOf().also { it[at] = (it[at].toInt() xor 1).toByte() }
            expectError(SmsCryptoException.Code.WRONG_PASSWORD) { KeyFile.open(bad, "RIGHT", org.anchors) }
        }
    }

    @Test
    fun `a secret the certificate does not name is refused`() {
        val org = Org(random)
        val ali = Issuer.issue(org.authority, org.roster.entries[0])
        val maryam = Issuer.issue(org.authority, org.roster.entries[1])
        // Maryam's secret under Ali's certificate.
        expectError(SmsCryptoException.Code.BAD_BUNDLE) {
            KeyFile.open(forged(maryam.identity, ali.cert, "PW"), "PW", org.anchors)
        }
        // A stranger's secret under Ali's certificate.
        expectError(SmsCryptoException.Code.BAD_BUNDLE) {
            KeyFile.open(forged(IdentityKeyPair.generate(random), ali.cert, "PW"), "PW", org.anchors)
        }
        // The tool cannot write such a file in the first place.
        assertThrows(IllegalArgumentException::class.java) {
            KeyFile.create(maryam.identity, ali.cert, "PW", random, cheap)
        }
    }

    @Test
    fun `a certificate signed by another authority is refused`() {
        val org = Org(random)
        val maryam = Issuer.issue(org.authority, org.roster.entries[1])
        val other = MemberCert.issue(AuthorityKey.generate(random), "09122222222", 0, maryam.identity)
        expectError(SmsCryptoException.Code.UNTRUSTED) {
            KeyFile.open(KeyFile.create(maryam.identity, other, "PW", random, cheap), "PW", org.anchors)
        }
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
        val contents = AuthorityFile.Contents(AuthorityKey.generate(random))
        val file = AuthorityFile.create(contents, "a long passphrase", random, cheap)
        val opened = AuthorityFile.open(file, "a long passphrase")
        assertArrayEquals(contents.key.serialize(), opened.key.serialize())
        expectError(SmsCryptoException.Code.WRONG_PASSWORD) { AuthorityFile.open(file, "A long passphrase") }
        expectError(SmsCryptoException.Code.NOT_A_KEY_FILE) { AuthorityFile.open(keyFile(Org(random), 0, "x"), "x") }
        assertThrows(IllegalArgumentException::class.java) { AuthorityFile.create(contents, "short", random, cheap) }
    }

    @Test
    fun `the key file format is frozen`() {
        val r = FixedRandom(1405)
        val authority = AuthorityKey.generate(r)
        val issued = Issuer.issue(authority, Issuer.Entry("مریم", listOf("09122222222", "02188776655"), 1))
        val file = KeyFile.create(issued.identity, issued.cert, "PW", r, cheap)
        assertEquals(GOLDEN_AUTHORITY_ID, Hex.toHexString(authority.public.authorityId))
        assertEquals(GOLDEN_MEMBER_KID, Hex.toHexString(issued.cert.keyId))
        assertEquals(GOLDEN_KEY_FILE_SHA, sha(file))
    }

    private fun sha(b: ByteArray) =
        Hex.toHexString(java.security.MessageDigest.getInstance("SHA-256").digest(b))

    private companion object {
        const val GOLDEN_AUTHORITY_ID = "e09334807b8501e0"
        const val GOLDEN_MEMBER_KID = "72cadfdd2e2336fe"
        const val GOLDEN_KEY_FILE_SHA = "96532c6f0529db1415961d55a1ac129aeb830228ae04737c68a378c7ea9cef03"
    }
}
