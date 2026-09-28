package com.example.communication_super_app.smscrypto

import java.security.SecureRandom
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GroupPayloadTest {
    private val gid = ByteArray(Payload.GROUP_ID_BYTES) { (it + 1).toByte() }
    private fun kid(n: Int) = ByteArray(PublicIdentity.KEY_ID_BYTES) { n.toByte() }

    private fun info(
        members: List<Payload.GroupMember> = listOf(
            Payload.GroupMember("09121111111", kid(1)), // odd digit count
            Payload.GroupMember("989122222222", kid(2)), // even
        ),
        name: String = "تیم میدانی ۳",
        mode: Int = Payload.GROUP_MODE_CHAT,
        version: Long = 7,
    ) = Payload.GroupInfo(gid, version, mode, name, members)

    @Test
    fun `a group message carries its group id in either encoding`() {
        for (text in listOf("سلام به همه", "hello all")) {
            for (del in listOf(false, true)) {
                val p = Payload.parse(Payload.groupText(gid, text, del)) as Payload.Text
                assertEquals(text, p.text)
                assertEquals(del, p.deleteAfterSeen)
                assertArrayEquals(gid, p.groupId)
            }
        }
        // A one-to-one message has none.
        assertNull((Payload.parse(Payload.text("x")) as Payload.Text).groupId)
    }

    @Test
    fun `a group message costs the id and nothing else`() {
        val text = "جلسه ساعت ۱۰"
        assertEquals(
            Payload.text(text).size + Payload.GROUP_ID_BYTES,
            Payload.groupText(gid, text).size,
        )
    }

    @Test
    fun `group info survives the round trip`() {
        val got = Payload.parse(Payload.groupInfo(info())) as Payload.GroupInfo
        assertArrayEquals(gid, got.groupId)
        assertEquals(7L, got.version)
        assertEquals(Payload.GROUP_MODE_CHAT, got.mode)
        assertEquals("تیم میدانی ۳", got.name)
        assertEquals(listOf("09121111111", "989122222222"), got.members.map { it.phone })
        assertArrayEquals(kid(2), got.members[1].keyId)

        val announce = Payload.parse(Payload.groupInfo(info(mode = Payload.GROUP_MODE_ANNOUNCE)))
        assertEquals(Payload.GROUP_MODE_ANNOUNCE, (announce as Payload.GroupInfo).mode)
    }

    @Test
    fun `ten members fit in a few SMS parts`() {
        val members = (0 until 10).map { Payload.GroupMember("0912000000$it", kid(it)) }
        val bytes = Payload.groupInfo(info(members = members))
        // kind + id + version + mode + name + count + 10 × (1 + 6 + 8)
        assertTrue("was ${bytes.size}", bytes.size < 190)
    }

    @Test
    fun `malformed group payloads are refused`() {
        val good = Payload.groupInfo(info())
        val bad = listOf(
            good.copyOf(good.size - 1), // truncated
            good + byteArrayOf(0), // trailing byte
            good.copyOf().also { it[1 + 8 + 1] = 5 }, // unknown mode (version is one byte)
            byteArrayOf((Payload.KIND_SEEN or Payload.FLAG_GROUP).toByte()) + gid, // group flag on a control
            byteArrayOf((Payload.KIND_TEXT_UTF8 or Payload.FLAG_GROUP).toByte()) + gid.copyOf(5), // short id
        )
        for (payload in bad) {
            expectError(SmsCryptoException.Code.BAD_PAYLOAD) { Payload.parse(payload) }
        }
        // A digit nibble above 9.
        val nibble = good.copyOf()
        val firstDigits = 1 + 8 + 1 + 1 + 1 + PersianCodePage.encode("تیم میدانی ۳").size + 1 + 1
        nibble[firstDigits] = 0xA9.toByte()
        expectError(SmsCryptoException.Code.BAD_PAYLOAD) { Payload.parse(nibble) }
    }

    @Test
    fun `group info refuses what it cannot carry`() {
        for (block in listOf(
            { Payload.groupInfo(info(members = emptyList())) },
            { Payload.groupInfo(info(members = listOf(Payload.GroupMember("+98912", kid(1))))) },
            { Payload.groupInfo(info(mode = 3)) },
            { Payload.groupInfo(info(name = "ن".repeat(201))) },
        )) {
            try {
                block()
                throw AssertionError("accepted")
            } catch (e: IllegalArgumentException) {
                // expected
            }
        }
    }

    @Test
    fun `group info travels as a control packet and a group message as a message`() {
        val s = handshake(Members(SecureRandom()))
        val infoSealed = s.alice.seal(Payload.groupInfo(info()), control = true)
        val infoPacket = Wire.parse(infoSealed.wire) as Packet.Message
        assertTrue(infoPacket.control)
        val opened = s.bob.open(infoPacket)
        assertEquals("تیم میدانی ۳", (Payload.parse(opened.payload) as Payload.GroupInfo).name)

        val text = infoSealed.session.seal(Payload.groupText(gid, "سلام"))
        val textPacket = Wire.parse(text.wire) as Packet.Message
        assertTrue(!textPacket.control)
        val got = Payload.parse(opened.session.open(textPacket).payload) as Payload.Text
        assertArrayEquals(gid, got.groupId)
    }
}
