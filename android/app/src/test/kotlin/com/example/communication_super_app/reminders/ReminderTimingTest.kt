package com.example.communication_super_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReminderTimingTest {
    private val now = 1_000_000_000L
    private val day = ReminderTiming.ALARM_CLOCK_HORIZON_MS

    @Test
    fun withinADayTheReminderItselfIsAnAlarmClock() {
        val wake = ReminderTiming.wakeFor(now + 60_000, now)
        assertEquals(now + 60_000, wake.at)
        assertTrue(wake.asAlarmClock)
        assertTrue(ReminderTiming.wakeFor(now + day, now).asAlarmClock)
    }

    @Test
    fun furtherOutItWakesADayBeforeToArmTheAlarmClock() {
        val wake = ReminderTiming.wakeFor(now + 3 * day, now)
        assertEquals(now + 2 * day, wake.at)
        assertFalse(wake.asAlarmClock)
        // The wake-up itself lands inside the horizon.
        val next = ReminderTiming.wakeFor(now + 3 * day, wake.at)
        assertEquals(now + 3 * day, next.at)
        assertTrue(next.asAlarmClock)
    }

    @Test
    fun anOverdueReminderFiresNow() {
        val wake = ReminderTiming.wakeFor(now - 5_000, now)
        assertEquals(now, wake.at)
        assertTrue(wake.asAlarmClock)
    }
}
