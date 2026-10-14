package com.example.communication_super_app.call

import com.example.communication_super_app.call.CallRules.Rules
import com.example.communication_super_app.call.CallRules.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CallRulesTest {

    private val stranger: () -> Boolean? = { false }
    private val contact: () -> Boolean? = { true }
    private val unknownBook: () -> Boolean? = { null }
    private val never: () -> Boolean = { false }

    private fun failIfAsked(): () -> Boolean? = { throw AssertionError("contacts were queried") }

    // ── International ───────────────────────────────────────────────────────

    @Test
    fun internationalNumbersAreThoseDialledFromAnotherCountry() {
        assertTrue(CallRules.isInternational("+14155550100"))
        assertTrue(CallRules.isInternational("+44 20 7946 0958"))
        assertTrue(CallRules.isInternational("0014155550100"))
        assertTrue(CallRules.isInternational("+971501234567"))
    }

    @Test
    fun everyDomesticSpellingIsDomestic() {
        assertFalse(CallRules.isInternational("+989121234567"))
        assertFalse(CallRules.isInternational("00989121234567"))
        assertFalse(CallRules.isInternational("989121234567"))
        assertFalse(CallRules.isInternational("09121234567"))
        assertFalse(CallRules.isInternational("02188776655"))
        assertFalse(CallRules.isInternational("+982188776655"))
        assertFalse(CallRules.isInternational(""))
    }

    // ── Prefixes ────────────────────────────────────────────────────────────

    @Test
    fun prefixesAreNormalisedToTheNationalForm() {
        assertEquals("0942", CallRules.normalizePrefix("0942"))
        assertEquals("0942", CallRules.normalizePrefix("+98942"))
        assertEquals("0942", CallRules.normalizePrefix("98942"))
        assertEquals("0942", CallRules.normalizePrefix("0098942"))
        assertEquals("0942", CallRules.normalizePrefix("942"))
        assertEquals("0942", CallRules.normalizePrefix("۰۹۴۲"))
        assertEquals("02191", CallRules.normalizePrefix("021 91"))
    }

    @Test
    fun tooShortOrForeignPrefixesAreRefused() {
        assertNull(CallRules.normalizePrefix("09"))
        assertNull(CallRules.normalizePrefix("091"))
        assertNull(CallRules.normalizePrefix(""))
        assertNull(CallRules.normalizePrefix("+1415"))
    }

    @Test
    fun aPrefixMatchesEverySpellingOfTheNumber() {
        val prefixes = setOf("0942")
        assertTrue(CallRules.matchesPrefix("09421234567", prefixes))
        assertTrue(CallRules.matchesPrefix("+989421234567", prefixes))
        assertTrue(CallRules.matchesPrefix("00989421234567", prefixes))
        assertFalse(CallRules.matchesPrefix("09121234567", prefixes))
        assertFalse(CallRules.matchesPrefix("09421234567", emptySet()))
    }

    // ── Decisions ───────────────────────────────────────────────────────────

    @Test
    fun nothingSwitchedOnNeverLooksAnythingUp() {
        assertEquals(
            Verdict.ALLOW,
            CallRules.decide("+14155550100", Rules(), failIfAsked(), never),
        )
    }

    @Test
    fun aStrangerIsRefusedByTheContactsRule() {
        assertEquals(
            Verdict.NON_CONTACT,
            CallRules.decide("09121234567", Rules(nonContacts = true), stranger, never),
        )
    }

    @Test
    fun aContactIsAlwaysLetThrough() {
        val all = Rules(nonContacts = true, international = true, advertising = true,
            adPrefixes = setOf("0942"))
        assertEquals(Verdict.ALLOW, CallRules.decide("09421234567", all, contact, never))
        assertEquals(Verdict.ALLOW, CallRules.decide("+14155550100", all, contact, never))
    }

    @Test
    fun aNumberTheUserJustCalledIsLetThrough() {
        assertEquals(
            Verdict.ALLOW,
            CallRules.decide("09121234567", Rules(nonContacts = true), stranger) { true },
        )
    }

    @Test
    fun anUnreadableAddressBookDoesNotBlockEveryone() {
        assertEquals(
            Verdict.ALLOW,
            CallRules.decide("09121234567", Rules(nonContacts = true), unknownBook, never),
        )
    }

    @Test
    fun theForeignRuleStillHoldsWithoutTheAddressBook() {
        assertEquals(
            Verdict.INTERNATIONAL,
            CallRules.decide("+14155550100", Rules(international = true), unknownBook, never),
        )
    }

    @Test
    fun aDomesticStrangerPassesTheForeignRuleWithoutALookup() {
        assertEquals(
            Verdict.ALLOW,
            CallRules.decide("09121234567", Rules(international = true), failIfAsked(), never),
        )
    }

    @Test
    fun anAdvertisingPrefixIsRefused() {
        val rules = Rules(advertising = true, adPrefixes = setOf("0942"))
        assertEquals(Verdict.ADVERTISING, CallRules.decide("09421234567", rules, stranger, never))
        assertEquals(Verdict.ALLOW, CallRules.decide("09121234567", rules, failIfAsked(), never))
    }

    @Test
    fun serviceNumbersAreNeverBlockedByARule() {
        val all = Rules(nonContacts = true, international = true, advertising = true,
            adPrefixes = setOf("0942"))
        for (n in listOf("110", "115", "125", "1818", "9990")) {
            assertEquals(n, Verdict.ALLOW, CallRules.decide(n, all, failIfAsked(), never))
        }
    }

    @Test
    fun theContactsRuleIsReportedFirstWhenSeveralApply() {
        val all = Rules(nonContacts = true, international = true)
        assertEquals(Verdict.NON_CONTACT, CallRules.decide("+14155550100", all, stranger, never))
    }
}
