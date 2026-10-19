package com.example.communication_super_app.sim

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A call-log account id that is the card's ICC ID is spelled differently from
 * build to build — with or without the `F` padding, upper or lower case, one
 * digit longer — and an exact comparison then missed every call on that card:
 * no SIM badge, ever (reported on a dual-SIM phone, SIM 2).
 */
class IccMatchTest {
    private val icc = "8998432001234567890"

    @Test
    fun `spellings of one ICC ID match`() {
        assertTrue(SimRegistry.iccMatches(icc, icc))
        assertTrue(SimRegistry.iccMatches(icc + "F", icc))
        assertTrue(SimRegistry.iccMatches(icc.lowercase() + "f", icc))
        assertTrue(SimRegistry.iccMatches(icc + "3", icc)) // the check digit kept
        assertTrue(SimRegistry.iccMatches(icc, icc + "3"))
        assertTrue(SimRegistry.iccMatches(" $icc ", icc))
    }

    @Test
    fun `other cards and short ids do not`() {
        assertFalse(SimRegistry.iccMatches("8998432001234567891", icc))
        assertFalse(SimRegistry.iccMatches("10", "1"))
        assertFalse(SimRegistry.iccMatches("1", "10"))
        assertFalse(SimRegistry.iccMatches(null, icc))
        assertFalse(SimRegistry.iccMatches(icc, ""))
        assertFalse(SimRegistry.iccMatches("FFFF", "FF"))
    }
}
