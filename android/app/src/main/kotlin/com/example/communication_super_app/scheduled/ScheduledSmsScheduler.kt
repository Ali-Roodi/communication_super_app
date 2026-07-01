package com.example.communication_super_app.scheduled

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import kotlin.random.Random

/**
 * Schedules a single AlarmManager alarm for the soonest pending scheduled
 * message. After each alarm fires (and messages are processed) the receiver
 * calls [reschedule] again for the new earliest message, so one alarm is enough
 * regardless of how many messages are queued.
 */
object ScheduledSmsScheduler {
    private const val TAG = "ScheduledSmsScheduler"
    private const val REQUEST_CODE = 7801
    const val ACTION = "com.example.communication_super_app.SCHEDULED_SMS_ALARM"

    /** Point the alarm at the soonest pending message, or cancel it if none. */
    fun reschedule(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pendingIntent(context)
        val earliest = ScheduledSmsWorker.earliestPending(context)
        if (earliest == null) {
            am.cancel(pi)
            Log.d(TAG, "No pending schedules; alarm cancelled")
            return
        }
        val now = System.currentTimeMillis()
        // Apply the send-time jitter: fire at a random point within the window
        // after the nominal time. `scheduled_at` (the recurrence base) is left
        // untouched, so recurring messages don't drift. Overdue messages fire
        // immediately with no jitter.
        val trigger = if (earliest.at <= now) {
            now
        } else {
            val windowMs = earliest.jitterMinutes * 60_000L
            earliest.at + if (windowMs > 0) Random.nextLong(0, windowMs + 1) else 0L
        }
        try {
            val exactAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                am.canScheduleExactAlarms()
            if (exactAllowed) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
            } else {
                // Exact alarms not permitted → fall back to an inexact wake-up.
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                Log.w(TAG, "Exact alarms not permitted; using inexact alarm")
            }
            Log.d(TAG, "Next scheduled-SMS alarm at $trigger")
        } catch (e: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
            Log.w(TAG, "SecurityException on exact alarm; used inexact: ${e.message}")
        }
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(context))
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, ScheduledSmsAlarmReceiver::class.java)
            .setAction(ACTION)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }
}
