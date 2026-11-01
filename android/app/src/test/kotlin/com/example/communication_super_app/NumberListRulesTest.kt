package com.example.communication_super_app

import com.example.communication_super_app.NumberListRules.Channel
import com.example.communication_super_app.NumberListRules.Config
import com.example.communication_super_app.NumberListRules.Mode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NumberListRulesTest {

    private val notHidden: () -> Boolean = { false }
    private val hidden: () -> Boolean = { true }
    private val stranger: () -> Boolean? = { false }
    private val contact: () -> Boolean? = { true }
    private val unknownBook: () -> Boolean? = { null }

    private fun failIfAsked(): () -> Boolean? = { throw AssertionError("contacts were queried") }

    private fun allows(
        raw: String,
        config: Config,
        channel: Channel = Channel.SMS_IN,
        isHidden: () -> Boolean = notHidden,
        isContact: () -> Boolean? = stranger,
    ) = NumberListRules.allows(raw, channel, config, isHidden, isContact)

    private fun only(channel: Channel, mode: Mode) = mapOf(channel to mode)

    // ── Patterns ────────────────────────────────────────────────────────────

    /** The same vectors pin `NumberLists.normalizePattern` in Dart. */
    @Test
    fun `patterns are normalised to the national form`() {
        assertEquals("09121234567", NumberListRules.normalizePattern("09121234567"))
        assertEquals("09121234567", NumberListRules.normalizePattern("+98 912 123 4567"))
        assertEquals("09121234567", NumberListRules.normalizePattern("00989121234567"))
        assertEquals("09121234567", NumberListRules.normalizePattern("989121234567"))
        assertEquals("09121234567", NumberListRules.normalizePattern("9121234567"))
        assertEquals("09121234567", NumberListRules.normalizePattern("۰۹۱۲-۱۲۳-۴۵۶۷"))
        assertEquals("0912*", NumberListRules.normalizePattern("0912*"))
        assertEquals("0912*", NumberListRules.normalizePattern("+98912**"))
        assertEquals("*1234", NumberListRules.normalizePattern("*۱۲۳۴"))
        assertEquals("0912???4567", NumberListRules.normalizePattern("0912؟؟؟4567"))
        assertEquals("021*", NumberListRules.normalizePattern("021 *"))
    }

    @Test
    fun `unusable patterns are refused`() {
        assertNull(NumberListRules.normalizePattern(""))
        assertNull(NumberListRules.normalizePattern("*"))
        assertNull(NumberListRules.normalizePattern("09*")) // two digits
        assertNull(NumberListRules.normalizePattern("0912abc"))
        assertNull(NumberListRules.normalizePattern("+14155550100")) // foreign
        assertNull(NumberListRules.normalizePattern("0014155550100"))
        assertNull(NumberListRules.normalizePattern("2188776655")) // no leading 0
        assertNull(NumberListRules.normalizePattern("110")) // a service number
        assertNull(NumberListRules.normalizePattern("0912*1*2*3*4*5*6*7*8*9"))
    }

    @Test
    fun `wildcards match whole numbers only`() {
        assertTrue(NumberListRules.matches("0912*", "09121234567"))
        assertFalse(NumberListRules.matches("0912*", "09351234567"))
        assertTrue(NumberListRules.matches("*4567", "09121234567"))
        assertFalse(NumberListRules.matches("*4567", "09121234568"))
        assertTrue(NumberListRules.matches("0912???4567", "09121234567"))
        assertFalse(NumberListRules.matches("0912???4567", "091212344567"))
        assertTrue(NumberListRules.matches("09*45*", "09121234567"))
        assertTrue(NumberListRules.matches("09121234567", "09121234567"))
        assertFalse(NumberListRules.matches("0912123456", "09121234567"))
    }

    // ── Modes ───────────────────────────────────────────────────────────────

    @Test
    fun `the default allows everybody without asking anything`() {
        val config = Config(white = listOf("0912*"))
        for (channel in Channel.values()) {
            assertTrue(
                NumberListRules.allows(
                    "09351234567", channel, config,
                    { throw AssertionError("hidden was queried") }, failIfAsked(),
                ),
            )
        }
    }

    @Test
    fun `the black list refuses what it matches, in every form`() {
        val config = Config(black = listOf("0912*", "09351112233"))
        assertFalse(allows("09121234567", config))
        assertFalse(allows("+989121234567", config))
        assertFalse(allows("۰۹۱۲۱۲۳۴۵۶۷", config))
        assertFalse(allows("+98 935 111 2233", config))
        assertTrue(allows("09351112234", config))
    }

    @Test
    fun `the white list allows only what it matches`() {
        val config = Config(modes = only(Channel.SMS_IN, Mode.WHITELIST), white = listOf("0912*"))
        assertTrue(allows("+989121234567", config))
        assertFalse(allows("09351234567", config))
        // The other channels keep the default.
        assertTrue(allows("09351234567", config, Channel.SMS_OUT))
    }

    @Test
    fun `an empty white list allows nobody`() {
        val config = Config(modes = only(Channel.CALL_IN, Mode.WHITELIST))
        assertFalse(allows("09121234567", config, Channel.CALL_IN))
    }

    @Test
    fun `contacts pass a white list only when asked to`() {
        val off = Config(modes = only(Channel.SMS_IN, Mode.WHITELIST))
        assertFalse(allows("09121234567", off, isContact = contact))
        val on = off.copy(contactsAllowed = true)
        assertTrue(allows("09121234567", on, isContact = contact))
        assertFalse(allows("09121234567", on, isContact = stranger))
        // An address book that cannot be read lets the number through.
        assertTrue(allows("09121234567", on, isContact = unknownBook))
    }

    @Test
    fun `nobody refuses every subscriber`() {
        val config = Config(modes = only(Channel.CALL_OUT, Mode.NOBODY), white = listOf("0912*"))
        assertFalse(allows("09121234567", config, Channel.CALL_OUT, isContact = contact))
    }

    @Test
    fun `short numbers and names are never refused`() {
        val config = Config(modes = Channel.values().associateWith { Mode.NOBODY })
        for (raw in listOf("110", "115", "1818", "*140#", "MCI", "Hamrah-e Aval", "300012")) {
            for (channel in Channel.values()) {
                assertTrue("$raw $channel", allows(raw, config, channel))
            }
        }
    }

    @Test
    fun `a hidden contact is never refused`() {
        val config = Config(
            modes = Channel.values().associateWith { Mode.NOBODY },
            black = listOf("0912*"),
        )
        for (channel in Channel.values()) {
            assertTrue(allows("09121234567", config, channel, isHidden = hidden))
        }
    }

    @Test
    fun `unknown keys read as the default`() {
        assertEquals(Mode.BLACKLIST, Mode.of(null))
        assertEquals(Mode.BLACKLIST, Mode.of("everything"))
        assertEquals(Mode.WHITELIST, Mode.of("whitelist"))
        assertNull(Channel.of("sms"))
        assertEquals(Channel.CALL_OUT, Channel.of("call_out"))
    }
}
