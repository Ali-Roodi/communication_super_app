package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.PublicIdentity
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * «دفترچهٔ کلید»: an organization's members and their public identities, as
 * the authority signed it.
 *
 * [directoryId] is fixed for an organization; [serial] grows with every
 * issue (the tool uses the issue time), so a phone keeps the newest copy of a
 * directory and refuses to go back to an older one — an old copy may still
 * list a member whose key was revoked.
 */
class Directory(
    val authorityId: ByteArray,
    val directoryId: ByteArray,
    val serial: Long,
    val name: String,
    val members: List<Member>,
) {
    class Member(val name: String, val phones: List<String>, val identity: PublicIdentity)

    companion object {
        private const val FORMAT = 1
        const val ID_BYTES = 8
        const val MAX_MEMBERS = 5000
        const val MAX_PHONES = 8

        internal fun decode(bytes: ByteArray): Directory {
            val r = BinReader(bytes, SmsCryptoException.Code.BAD_BUNDLE)
            if (r.u8() != FORMAT) r.fail("unknown directory format")
            val authorityId = r.raw(AuthorityPublic.ID_BYTES)
            val directoryId = r.raw(ID_BYTES)
            val serial = r.u64()
            val name = r.text()
            val count = r.u16()
            if (count == 0 || count > MAX_MEMBERS) r.fail("bad member count")
            val members = List(count) {
                val memberName = r.text()
                val phoneCount = r.u8()
                if (phoneCount == 0 || phoneCount > MAX_PHONES) r.fail("bad phone count")
                val phones = List(phoneCount) { r.text() }
                val identity = try {
                    PublicIdentity.parse(r.bytes16())
                } catch (e: SmsCryptoException) {
                    r.fail("invalid member key")
                }
                Member(memberName, phones, identity)
            }
            r.end()
            return Directory(authorityId, directoryId, serial, name, members).also { it.check() }
        }
    }

    /** Every phone canonical, no phone or key listed twice. */
    internal fun check() {
        val phones = HashSet<String>()
        val keys = HashSet<String>()
        for (m in members) {
            for (p in m.phones) {
                if (Canon.phone(p) != p) bad("phone number not canonical")
                if (!phones.add(p)) bad("phone number listed twice")
            }
            if (!keys.add(m.identity.keyId.joinToString("") { "%02x".format(it) })) bad("key listed twice")
        }
    }

    private fun bad(message: String): Nothing = cryptoError(SmsCryptoException.Code.BAD_BUNDLE, message)

    fun encode(): ByteArray {
        check()
        val w = BinWriter()
            .u8(FORMAT)
            .raw(authorityId)
            .raw(directoryId)
            .u64(serial)
            .text(name)
            .u16(members.size)
        for (m in members) {
            w.text(m.name).u8(m.phones.size)
            for (p in m.phones) w.text(p)
            w.bytes16(m.identity.encoded)
        }
        return w.toByteArray()
    }
}

/** A directory's exact bytes and the authority's signature over them. */
class SignedDirectory internal constructor(val bytes: ByteArray, val signature: ByteArray) {
    companion object {
        fun sign(directory: Directory, authority: AuthorityKey, random: SecureRandom): SignedDirectory {
            require(directory.authorityId.contentEquals(authority.public.authorityId)) {
                "directory names another authority"
            }
            val bytes = directory.encode()
            return SignedDirectory(bytes, authority.sign(bytes, random))
        }

        fun decode(encoded: ByteArray): SignedDirectory {
            val r = BinReader(encoded, SmsCryptoException.Code.BAD_BUNDLE)
            val bytes = r.bytes32()
            val signature = r.bytes16()
            r.end()
            return SignedDirectory(bytes, signature)
        }
    }

    fun encode(): ByteArray = BinWriter().bytes32(bytes).bytes16(signature).toByteArray()

    /**
     * The directory, if one of [anchors] signed it: UNTRUSTED when it names
     * an authority not among them, BAD_SIGNATURE when the signature fails.
     */
    fun verify(anchors: List<AuthorityPublic>): Directory {
        val directory = Directory.decode(bytes)
        val anchor = anchors.firstOrNull { MessageDigest.isEqual(it.authorityId, directory.authorityId) }
            ?: cryptoError(SmsCryptoException.Code.UNTRUSTED, "authority not trusted")
        if (!anchor.verify(bytes, signature)) {
            cryptoError(SmsCryptoException.Code.BAD_SIGNATURE, "signature does not verify")
        }
        return directory
    }
}
