package com.example.communication_super_app.reminders

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.communication_super_app.BlockedNumbers
import com.example.communication_super_app.MainActivity
import com.example.communication_super_app.NotificationAvatars
import com.example.communication_super_app.R
import com.example.communication_super_app.SmsNotifier
import com.example.communication_super_app.hidden.HiddenNumbers
import com.example.communication_super_app.security.NotificationPrivacy
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** One pending «یادآور»: who, call or SMS, and when. */
data class CallReminder(
    val id: String,
    val number: String,
    val kind: String,
    val at: Long,
    val name: String?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "number" to number,
        "kind" to kind,
        "at" to at,
        "name" to name,
    )
}

/** When to wake next, and how. */
internal data class ReminderWake(val at: Long, val asAlarmClock: Boolean)

internal object ReminderTiming {
    /** See [wakeFor]. A day bounds how long the system's alarm icon shows. */
    const val ALARM_CLOCK_HORIZON_MS = 24 * 60 * 60 * 1000L

    /**
     * Within a day the reminder itself is armed as an alarm clock, the only
     * alarm App Standby does not defer. Further out, an ordinary exact alarm
     * wakes the app a day before, and that wake-up arms the alarm clock: the
     * app may not be opened in between. Overdue reminders fire now.
     */
    fun wakeFor(earliest: Long, now: Long): ReminderWake {
        val trigger = maxOf(earliest, now)
        return if (trigger - now <= ALARM_CLOCK_HORIZON_MS) {
            ReminderWake(trigger, asAlarmClock = true)
        } else {
            ReminderWake(trigger - ALARM_CLOCK_HORIZON_MS, asAlarmClock = false)
        }
    }
}

/**
 * «یادآور تماس / پیامک» (matrix row 39), set from a row of «اخیر».
 *
 * Kotlin owns these because the alarm has to fire, and be re-armed after a
 * reboot, with no Flutter engine. They live in their own preferences file rather
 * than the main database: a list of a few rows, read whole, that nothing joins.
 *
 * A reminder leaves the list when it fires; «۱۰ دقیقه بعد» on its card makes a
 * new one.
 */
object CallReminders {
    private const val TAG = "CallReminders"
    private const val FILE = "call_reminders"
    private const val KEY_PENDING = "pending"

    private const val CHANNEL_ID = "call_reminder"
    private const val REQUEST_ALARM = 7803
    private const val REQUEST_SHOW = 7804

    /** Above every other bare id this app posts (7001 and up, 0x5EC0). */
    private const val NOTIF_ID_BASE = 0x20000

    private const val SNOOZE_MS = 10 * 60 * 1000L

    const val KIND_CALL = "call"
    const val KIND_SMS = "sms"

    /** On a card's deep links: the card to take down once the app has it. */
    private const val EXTRA_CARD_ID = "reminderCardId"

    const val ACTION_ALARM = "com.example.communication_super_app.CALL_REMINDER_ALARM"
    const val ACTION_SNOOZE = "com.example.communication_super_app.CALL_REMINDER_SNOOZE"
    const val EXTRA_NUMBER = "number"
    const val EXTRA_KIND = "kind"
    const val EXTRA_NAME = "name"
    const val EXTRA_NOTIF_ID = "notifId"

    /** Set while an engine is listening; called when the list changed natively. */
    @Volatile
    var onChanged: (() -> Unit)? = null

    // ── The list ────────────────────────────────────────────────────────────

    @Synchronized
    fun list(context: Context): List<CallReminder> = read(context).sortedBy { it.at }

    @Synchronized
    fun add(context: Context, number: String, kind: String, at: Long, name: String?): CallReminder {
        val reminder = CallReminder(UUID.randomUUID().toString(), number, kind, at, name)
        write(context, read(context) + reminder)
        rearm(context)
        return reminder
    }

    @Synchronized
    fun remove(context: Context, id: String) {
        write(context, read(context).filterNot { it.id == id })
        rearm(context)
    }

    /** The alarm rang: announces what is due, then points it at the next one. */
    @Synchronized
    fun fireDue(context: Context) {
        val now = System.currentTimeMillis()
        val (due, rest) = read(context).partition { it.at <= now }
        if (due.isNotEmpty()) {
            write(context, rest)
            due.filterNot { HiddenNumbers.isHidden(context, it.number) }
                .forEach { post(context, it) }
            onChanged?.invoke()
        }
        rearm(context)
    }

    /** «۱۰ دقیقه بعد» on a card. */
    fun snooze(context: Context, number: String, kind: String, name: String?, notifId: Int) {
        nm(context).cancel(notifId)
        add(context, number, kind, System.currentTimeMillis() + SNOOZE_MS, name)
        onChanged?.invoke()
    }

    /**
     * A number just went into the hidden phonebook, which leaves no trace
     * outside the secure section: its reminders go too.
     */
    @Synchronized
    fun dropHidden(context: Context) {
        val all = read(context)
        val kept = all.filterNot { HiddenNumbers.isHidden(context, it.number) }
        if (kept.size == all.size) return
        write(context, kept)
        rearm(context)
        onChanged?.invoke()
    }

    private fun read(context: Context): List<CallReminder> {
        val raw = prefs(context).getString(KEY_PENDING, null) ?: return emptyList()
        return try {
            val rows = JSONArray(raw)
            List(rows.length()) { i ->
                val row = rows.getJSONObject(i)
                CallReminder(
                    id = row.getString("id"),
                    number = row.getString("number"),
                    kind = row.getString("kind"),
                    at = row.getLong("at"),
                    name = if (row.isNull("name")) null else row.getString("name"),
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "unreadable list: ${e.javaClass.simpleName}")
            emptyList()
        }
    }

    private fun write(context: Context, reminders: List<CallReminder>) {
        val rows = JSONArray()
        for (r in reminders) {
            rows.put(
                JSONObject()
                    .put("id", r.id)
                    .put("number", r.number)
                    .put("kind", r.kind)
                    .put("at", r.at)
                    .put("name", r.name ?: JSONObject.NULL),
            )
        }
        // commit, not apply: the process may die right after the alarm is armed.
        prefs(context).edit().putString(KEY_PENDING, rows.toString()).commit()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    // ── The alarm ───────────────────────────────────────────────────────────

    /**
     * Points the one alarm at the soonest reminder. An alarm is not durable
     * state, so this also runs after a reboot and on every return to the app.
     */
    @Synchronized
    fun rearm(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val alarm = alarmIntent(context)
        val earliest = read(context).minOfOrNull { it.at }
        if (earliest == null) {
            am.cancel(alarm)
            return
        }
        val wake = ReminderTiming.wakeFor(earliest, System.currentTimeMillis())
        try {
            if (wake.asAlarmClock) {
                am.setAlarmClock(AlarmManager.AlarmClockInfo(wake.at, showIntent(context)), alarm)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, wake.at, alarm)
            }
        } catch (e: SecurityException) {
            // SCHEDULE_EXACT_ALARM revoked: late is better than silent.
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, wake.at, alarm)
        }
    }

    private fun alarmIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST_ALARM,
        Intent(context, CallReminderReceiver::class.java).setAction(ACTION_ALARM),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** What the system's alarm icon opens — never the alarm broadcast itself. */
    private fun showIntent(context: Context): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return null
        return PendingIntent.getActivity(
            context,
            REQUEST_SHOW,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // ── The card ────────────────────────────────────────────────────────────

    /** Whether a reminder can reach the user at all. */
    fun alertsEnabled(context: Context): Boolean {
        val nm = nm(context)
        if (!nm.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        val channel = nm.getNotificationChannel(CHANNEL_ID) ?: return true
        return channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun post(context: Context, r: CallReminder) {
        ensureChannel(context)
        val notifId = NOTIF_ID_BASE + (r.id.hashCode() and 0xFFFF)
        // Three request codes per card: the two links and the snooze.
        val base = notifId * 3
        val dial = deepLink(context, KIND_CALL, r.number, notifId, base)
        val sms = deepLink(context, KIND_SMS, r.number, notifId, base + 1)
        val isCall = r.kind == KIND_CALL
        val open = if (isCall) dial else sms
        // The moment it rang, not the moment it was set for: after a long time
        // switched off that can be old enough for the system to drop the card.
        val rang = System.currentTimeMillis()

        // The app is locked behind its PIN: nobody is named and nothing can be
        // done from outside the lock. Tapping still goes to the same place,
        // behind the PIN screen.
        if (NotificationPrivacy.hideContent(context)) {
            nm(context).notify(notifId, privateCard(context, rang, open, silent = false))
            return
        }

        val contactName = SmsNotifier.lookupContactName(context, r.number) ?: r.name
        val snooze = PendingIntent.getBroadcast(
            context,
            base + 2,
            Intent(context, CallReminderReceiver::class.java)
                .setAction(ACTION_SNOOZE)
                .putExtra(EXTRA_NUMBER, r.number)
                .putExtra(EXTRA_KIND, r.kind)
                .putExtra(EXTRA_NAME, r.name)
                .putExtra(EXTRA_NOTIF_ID, notifId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val dialAction = NotificationCompat.Action(0, "شماره‌گیری", dial)
        val smsAction = NotificationCompat.Action(0, "پیامک", sms)
        val card = baseCard(context, rang, open, silent = false)
            .setLargeIcon(
                NotificationAvatars.letterAvatar(
                    contactName,
                    BlockedNumbers.normalizeToThreadId(r.number),
                ),
            )
            .setContentTitle(if (isCall) "یادآور تماس" else "یادآور پیامک")
            .setContentText(contactName ?: r.number)
            .addAction(if (isCall) dialAction else smsAction)
            .addAction(if (isCall) smsAction else dialAction)
            .addAction(NotificationCompat.Action(0, "۱۰ دقیقه بعد", snooze))
            // Folded into [privateCard] if the app locks while it is up.
            .addExtras(NotificationPrivacy.revealing(NotificationPrivacy.KIND_REMINDER, 1))
            .build()
        nm(context).notify(notifId, card)
    }

    /** What a card says while the app is locked. */
    fun privateCard(
        context: Context,
        whenMs: Long,
        contentIntent: PendingIntent?,
        silent: Boolean,
    ): Notification {
        ensureChannel(context)
        return baseCard(context, whenMs, contentIntent, silent)
            .setContentTitle("یادآور")
            .setContentText("برای دیدن، برنامه را باز کنید")
            .build()
    }

    private fun baseCard(
        context: Context,
        whenMs: Long,
        contentIntent: PendingIntent?,
        silent: Boolean,
    ) = NotificationCompat.Builder(context, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_call)
        .setCategory(NotificationCompat.CATEGORY_REMINDER)
        .setPriority(NotificationCompat.PRIORITY_HIGH)
        .setDefaults(NotificationCompat.DEFAULT_ALL)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .setAutoCancel(true)
        .setContentIntent(contentIntent)
        .setWhen(whenMs)
        .setShowWhen(true)
        .setSilent(silent)

    /**
     * Into the app with the number: `tel:` opens the keypad and `threadId` the
     * conversation, through the same intent handling as any other deep link.
     */
    private fun deepLink(
        context: Context,
        kind: String,
        number: String,
        notifId: Int,
        requestCode: Int,
    ): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_CARD_ID, notifId)
        if (kind == KIND_CALL) {
            intent.setAction(Intent.ACTION_DIAL).setData(Uri.fromParts("tel", number, null))
        } else {
            intent.putExtra("threadId", BlockedNumbers.normalizeToThreadId(number))
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** An action button does not auto-cancel its card, so the app does it. */
    fun consumeCardId(context: Context, intent: Intent) {
        if (!intent.hasExtra(EXTRA_CARD_ID)) return
        nm(context).cancel(intent.getIntExtra(EXTRA_CARD_ID, 0))
        intent.removeExtra(EXTRA_CARD_ID)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        nm(context).createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "یادآور تماس و پیامک",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "هشدار یادآورهایی که از «اخیر» تنظیم شده‌اند"
                // It says nothing is unread, so it stays off the launcher count.
                setShowBadge(false)
            },
        )
    }

    private fun nm(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
