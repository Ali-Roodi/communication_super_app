package com.example.communication_super_app.security

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log

/**
 * Whether opening the app right now would ask for its PIN — the question
 * «پنهان کردن محتوای اعلان‌ها» actually turns on. A notification is private
 * only while the app is **locked**; while it is open in front of the user, or
 * sitting in the background inside its «قفل خودکار» window (coming back would
 * not ask for the PIN either), the cards are the ordinary ones.
 *
 * Dart owns the decision and reports it (`AuthRepository.reportSession`):
 * [unlocked] after a right PIN, a fingerprint, or a return that did not
 * re-lock; [locked] when it re-locks. This side owns the one part Dart cannot
 * do on time — the clock while the app is in the background, when Dart may
 * not get to run at all: [backgrounded] (from `MainActivity.onStop`) starts the
 * «قفل خودکار» window, and when it runs out an alarm turns the full cards the
 * window let through into private ones ([NotificationPrivacy.privatizeActive]).
 *
 * In memory only, like the Dart flag it mirrors: a new process is locked.
 */
object AppLockSession {
    private const val TAG = "AppLockSession"
    private const val ACTION_DEADLINE =
        "com.example.communication_super_app.APP_LOCK_DEADLINE"
    private const val REQUEST_CODE = 0x414C

    /** `elapsedRealtime` until which the app opens without its PIN: 0 is
     *  locked, [Long.MAX_VALUE] is open in front of the user. */
    @Volatile
    private var openUntil = 0L

    /** «قفل خودکار», as Dart last reported it. */
    @Volatile
    private var graceMs = 60_000L

    fun isOpen(): Boolean = SystemClock.elapsedRealtime() < openUntil

    /** Unlocked. [inFront] false: reported while the app is not on screen,
     *  so the window starts now instead of at the next `onStop`. */
    @Synchronized
    fun unlocked(context: Context, graceSeconds: Int, inFront: Boolean) {
        graceMs = graceSeconds.coerceAtLeast(0) * 1000L
        Log.i(TAG, "open (inFront=$inFront, grace=${graceSeconds}s)")
        if (inFront) {
            openUntil = Long.MAX_VALUE
            cancelDeadline(context)
        } else {
            startWindow(context)
        }
    }

    /** The app left the screen. Only an open session starts a window; a
     *  locked one stays locked. */
    @Synchronized
    fun backgrounded(context: Context) {
        if (openUntil == Long.MAX_VALUE) startWindow(context)
    }

    /** Locked — re-locked by Dart, or the engine that held the session is
     *  gone. Whatever was announced in full while it was open is folded now. */
    @Synchronized
    fun locked(context: Context) {
        Log.i(TAG, "locked")
        openUntil = 0L
        cancelDeadline(context)
        NotificationPrivacy.privatizeActive(context)
    }

    private fun startWindow(context: Context) {
        if (graceMs <= 0L) {
            // «فوراً»: leaving is locking.
            Log.i(TAG, "away: locked at once")
            openUntil = 0L
            cancelDeadline(context)
            NotificationPrivacy.privatizeActive(context)
            return
        }
        val deadline = SystemClock.elapsedRealtime() + graceMs
        Log.i(TAG, "away: open for ${graceMs / 1000}s more")
        openUntil = deadline
        // No switch, nothing to fold when the window closes.
        if (NotificationPrivacy.switchedOn(context)) scheduleDeadline(context, deadline)
    }

    private fun scheduleDeadline(context: Context, at: Long) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = deadlineIntent(context)
            try {
                am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            } catch (e: SecurityException) {
                // Exact alarms refused: late is still better than never.
                am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            }
        } catch (e: Exception) {
            Log.w(TAG, "scheduleDeadline failed: ${e.javaClass.simpleName}")
        }
    }

    private fun cancelDeadline(context: Context) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(deadlineIntent(context))
        } catch (e: Exception) {
            Log.w(TAG, "cancelDeadline failed: ${e.javaClass.simpleName}")
        }
    }

    private fun deadlineIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST_CODE,
        Intent(context, DeadlineReceiver::class.java).setAction(ACTION_DEADLINE),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /**
     * The «قفل خودکار» window ran out with the app still away. If the process
     * died meanwhile this is a fresh one — locked by definition — and the
     * cards are folded all the same.
     */
    class DeadlineReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_DEADLINE) return
            Log.i(TAG, "window over (open=${isOpen()})")
            if (!isOpen()) NotificationPrivacy.privatizeActive(context)
        }
    }
}
