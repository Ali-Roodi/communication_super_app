package com.example.communication_super_app.scheduled

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Schedules a single AlarmManager alarm for the soonest pending scheduled
 * message. After each alarm fires (and messages are processed) the receiver
 * calls [reschedule] again for the new earliest message, so one alarm is enough
 * regardless of how many messages are queued.
 */
object ScheduledSmsScheduler {
    private const val TAG = "ScheduledSmsScheduler"
    private const val REQUEST_CODE = 7801
    private const val REQUEST_CODE_SHOW = 7802
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
        // `earliest.at` is already the *effective* send instant — the row's
        // jitter offset is baked in by `earliestPending`. It used to be rolled
        // here with a fresh `Random` while the deliverers computed their own
        // deterministic offset, so the alarm regularly woke the phone at a
        // moment both of them then refused as "window not open yet", handed the
        // row back to `pending`, and left the message waiting for a later
        // wake-up. Overdue rows fire immediately.
        val trigger = maxOf(earliest.at, now)
        try {
            if (trigger - now <= ALARM_CLOCK_HORIZON_MS) {
                // Imminent: `setAlarmClock` is the only alarm the platform will
                // not defer. `setExactAndAllowWhileIdle` escapes Doze but NOT
                // App Standby — an app the phone has decided is "rare" (which
                // is every app the user has not opened today, and on some OEM
                // builds every app they have not opened this hour) has its
                // exact alarms throttled to one every few hours. A message
                // promised for 09:00 that leaves at 11:00 is a broken feature,
                // so the alarm the user is about to depend on is armed as an
                // alarm clock. The cost is the system's next-alarm icon, which
                // is why it is not used for a schedule that is still days out.
                am.setAlarmClock(
                    AlarmManager.AlarmClockInfo(trigger, showIntent(context)),
                    pi,
                )
                Log.d(TAG, "Next scheduled-SMS alarm (alarm clock) at $trigger")
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                Log.d(TAG, "Next scheduled-SMS alarm at $trigger")
            }
        } catch (e: SecurityException) {
            // Exact alarms refused (SCHEDULE_EXACT_ALARM revoked by the user on
            // 12+). An inexact wake-up is late but not silent.
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
            Log.w(TAG, "SecurityException on exact alarm; used inexact: ${e.message}")
        }
    }

    /**
     * How close a schedule has to be before its alarm is armed as an alarm
     * clock rather than an exact-and-allow-while-idle alarm.
     *
     * A day: the app may not run again between now and the send, so the switch
     * has to happen while there is still a chance to make it, and a day bounds
     * how long the system's alarm icon can be showing for a message.
     */
    private const val ALARM_CLOCK_HORIZON_MS = 24 * 60 * 60 * 1000L

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(context))
    }

    /**
     * What the system's alarm-clock icon opens. The delivery intent must not be
     * reused for this — tapping the icon would fire the broadcast and send the
     * message early.
     */
    private fun showIntent(context: Context): PendingIntent? {
        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName) ?: return null
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, REQUEST_CODE_SHOW, launch, flags)
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
