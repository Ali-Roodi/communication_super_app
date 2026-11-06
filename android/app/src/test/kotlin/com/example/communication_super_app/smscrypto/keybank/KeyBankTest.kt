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

    // ── The 16-character code ───────────────────────────────────────────────

    private fun signers(vararg authorities: AuthorityKey) =
        authorities.map { MemberCode.Signer(it.public, it.sealedSigner()) }

    /** What a phone stores from either route. */
    private fun stored(o: KeyFile.Opened) = listOf(
        Hex.toHexString(o.authority.authorityId),
        Hex.toHexString(o.identity.serialize()),
        Hex.toHexString(o.cert.encoded),
        Hex.toHexString(o.cert.keyId),
    )

    @Test
    fun `the key file and the code give the same key and certificate, byte for byte`() {
        val org = Org(random)
        for (entry in org.roster.entries) {
            val issued = Issuer.issue(org.authority, entry)
            val password = Issuer.password(org.authority, entry)
            val fromFile = KeyFile.open(
                KeyFile.create(issued.identity, issued.cert, password, random, cheap),
                password,
                org.anchors,
            )
            val fromCode = MemberCode.open(Issuer.code(org.authority, entry), password, signers(org.authority))
            assertEquals(stored(fromFile), stored(fromCode))
            assertArrayEquals(issued.identity.serialize(), fromCode.identity.serialize())
            assertArrayEquals(issued.cert.encoded, fromCode.cert.encoded)
        }
    }

    @Test
    fun `a key built from a code talks to a key from a file`() {
        val org = Org(random)
        val entry = org.roster.entries[0]
        val ali = MemberCode.open(Issuer.code(org.authority, entry), Issuer.password(org.authority, entry), signers(org.authority))
        val maryam = KeyFile.open(keyFile(org, 1, "PW2"), "PW2", org.anchors)
        val started = CertHandshake.initiate(ali.cert, random)
        val responded = CertHandshake.respond(
            maryam.identity, maryam.cert, Wire.parse(started.wire) as Packet.Init, org.anchors, random,
        )
        val done = CertHandshake.complete(
            ali.identity, ali.cert, started.pending, Wire.parse(responded.wire) as Packet.Response, org.anchors,
        )
        assertEquals("سلام", responded.session.receive(done.session.send("سلام").wire).second)
    }

    @Test
    fun `nothing is built without the right code and password`() {
        val org = Org(random)
        val ali = org.roster.entries[0]
        val maryam = org.roster.entries[1]
        val code = Issuer.code(org.authority, ali)
        val password = Issuer.password(org.authority, ali)
        val signers = signers(org.authority)
        fun refused(c: String, p: String, s: List<MemberCode.Signer> = signers) =
            expectError(SmsCryptoException.Code.WRONG_PASSWORD) { MemberCode.open(c, p, s) }

        // Another member's password, or their code.
        refused(code, Issuer.password(org.authority, maryam))
        refused(Issuer.code(org.authority, maryam), password)
        // One character off, in each.
        val other = { c: Char -> if (c == 'A') 'B' else 'A' }
        refused(other(code[0]) + code.drop(1), password)
        refused(code, other(password[0]) + password.drop(1))
        // Too short, too long, characters the alphabet does not have.
        refused(code.dropLast(1), password)
        refused(code + "A", password)
        refused(code, password.dropLast(1))
        refused("O" + code.drop(1), password)
        // Another organization's code; an app that trusts nobody.
        val stranger = Org(random)
        refused(Issuer.code(stranger.authority, ali), Issuer.password(stranger.authority, ali))
        refused(code, password, emptyList())
    }

    @Test
    fun `the code and password are forgiving about how they are typed`() {
        val org = Org(random)
        val entry = org.roster.entries[1]
        val code = Issuer.code(org.authority, entry)
        val password = Issuer.password(org.authority, entry)
        val neat = stored(MemberCode.open(code, password, signers(org.authority)))
        val typed = MemberCode.open(
            code.replace("-", " ").lowercase(),
            password.replace("-", "").lowercase(),
            signers(org.authority),
        )
        assertEquals(neat, stored(typed))
    }

    @Test
    fun `the right signer is found among several`() {
        val org = Org(random)
        val entry = org.roster.entries[0]
        val opened = MemberCode.open(
            Issuer.code(org.authority, entry),
            Issuer.password(org.authority, entry),
            signers(AuthorityKey.generate(random), org.authority),
        )
        assertArrayEquals(org.authority.public.authorityId, opened.authority.authorityId)
    }

    @Test
    fun `a seal that is not the anchor's builds nothing`() {
        val org = Org(random)
        val entry = org.roster.entries[0]
        // The right secret, but under it the seed of another authority.
        val otherSeed = AuthorityKey.generate(random).serialize().copyOfRange(33, 65)
        val unlockFromCode = MemberCode.Signer(
            org.authority.public,
            sealWithTheOrganizationsSecret(org, otherSeed),
        )
        expectError(SmsCryptoException.Code.BAD_BUNDLE) {
            MemberCode.open(Issuer.code(org.authority, entry), Issuer.password(org.authority, entry), listOf(unlockFromCode))
        }
    }

    private fun sealWithTheOrganizationsSecret(org: Org, seed: ByteArray): ByteArray {
        val memberSeed = org.authority.serialize().copyOfRange(65, 97)
        val unlock = com.example.communication_super_app.smscrypto.Kdf.hkdf(
            memberSeed,
            "hamresan.authority.unlock.v1".toByteArray(Charsets.US_ASCII),
            ByteArray(0),
            MemberCode.UNLOCK_BYTES,
        )
        return MemberCode.sealSigner(seed, unlock, org.authority.public.authorityId)
    }

    @Test
    fun `the seal holds the signer only, and every member's key is their own`() {
        // Opening the seal gives the signer and the unlock secret. A member's key
        // also needs that member's password, which takes the member seed to make,
        // and the member seed is not in what the app is given.
        val org = Org(random)
        val sealed = org.authority.sealedSigner()
        assertEquals(MemberCode.SEALED_SIGNER_BYTES, sealed.size)
        val memberSeed = org.authority.serialize().copyOfRange(65, 97)
        assertFalse(Hex.toHexString(sealed).contains(Hex.toHexString(memberSeed)))
        val ali = Issuer.Entry("علی", listOf("09121111111"), 0)
        val maryam = Issuer.Entry("مریم", listOf("09122222222"), 0)
        assertFalse(Issuer.password(org.authority, ali) == Issuer.password(org.authority, maryam))
        assertFalse(
            Issuer.issue(org.authority, ali).identity.x25519Public
                .contentEquals(Issuer.issue(org.authority, maryam).identity.x25519Public),
        )
    }

    @Test
    fun `passwords are 20 unambiguous characters and carry their number`() {
        val org = Org(random)
        for (n in 0 until 20) {
            val phone = "09" + (100000000 + n * 44444444).toString().padStart(9, '0')
            val p = org.authority.memberPassword(phone, n * 13)
            assertTrue(p, Regex("^([2-9A-HJ-NP-Z]{4}-){4}[2-9A-HJ-NP-Z]{4}$").matches(p))
            // The number is not readable from the characters themselves, but is from the password.
            val named = MemberCode.named(p)!!
            assertEquals(phone, named.phone)
            assertEquals(n * 13, named.generation)
        }
        assertEquals("09000000000", MemberCode.named(org.authority.memberPassword("09000000000", 0))!!.phone)
        assertEquals("09999999999", MemberCode.named(org.authority.memberPassword("09999999999", 255))!!.phone)
    }

    @Test
    fun `a new generation or number means a new password and code`() {
        val org = Org(random)
        val a = org.authority
        assertEquals(a.memberPassword("09121111111", 0), a.memberPassword("09121111111", 0))
        assertEquals(a.memberCode("09121111111", 0), a.memberCode("09121111111", 0))
        assertFalse(a.memberPassword("09121111111", 0) == a.memberPassword("09121111111", 1))
        assertFalse(a.memberPassword("09121111111", 0) == a.memberPassword("09121111112", 0))
        assertFalse(a.memberCode("09121111111", 0) == a.memberCode("09121111111", 1))
        assertThrows(IllegalArgumentException::class.java) { a.memberPassword("02188776655", 0) }
        assertThrows(IllegalArgumentException::class.java) { a.memberPassword("09121111111", 256) }
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
        val entry = Issuer.Entry("مریم", listOf("09122222222", "02188776655"), 1)
        val issued = Issuer.issue(authority, entry)
        val file = KeyFile.create(issued.identity, issued.cert, "PW", r, cheap)
        assertEquals(GOLDEN_AUTHORITY_ID, Hex.toHexString(authority.public.authorityId))
        assertEquals(GOLDEN_MEMBER_KID, Hex.toHexString(issued.cert.keyId))
        assertEquals(GOLDEN_KEY_FILE_SHA, sha(file))
        assertEquals(GOLDEN_PASSWORD, Issuer.password(authority, entry))
        assertEquals(GOLDEN_CODE, Issuer.code(authority, entry))
        assertEquals(GOLDEN_SEALED_SIGNER, Hex.toHexString(authority.sealedSigner()))
    }

    private fun sha(b: ByteArray) =
        Hex.toHexString(java.security.MessageDigest.getInstance("SHA-256").digest(b))

    private companion object {
        const val GOLDEN_AUTHORITY_ID = "e09334807b8501e0"
        const val GOLDEN_MEMBER_KID = "b23e9167b96fe5cc"
        const val GOLDEN_KEY_FILE_SHA = "4b2eb0e2665c4c8fa7d07db77f485a15745e0a0246cae034cb31ff6dc1b6a6e7"
        const val GOLDEN_PASSWORD = "HW6P-6QYP-5FGE-58TG-RGPQ"
        const val GOLDEN_CODE = "EGB7-3SXD-3545-A2EH"
        const val GOLDEN_SEALED_SIGNER = "770c8781e62808f300f7e917930a2c6efe98f8b29a96c401751b0b94f306ae4f1e6cfcf506f5589084ed37e3838f6f25"
    }
}
