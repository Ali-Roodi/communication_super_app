package com.example.communication_super_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.example.communication_super_app.call.CallInCallService
import com.example.communication_super_app.sim.SimRegistry

/**
 * Single notification pipeline for incoming SMS — used by BOTH receive paths
 * (cold-start [IncomingSmsReceiver] and the live [SmsHandler] dynamic
 * receiver), so every SMS notification has the same look and the same
 * fully-native actions:
 *
 * - **پاسخ** — inline RemoteInput reply, sent by [SmsNotificationActionReceiver]
 *   with SmsManager directly (works with the app dead, backgrounded or open).
 * - **خواندم** — marks the thread read straight in the DB.
 * - Tap — launches MainActivity with a `threadId` extra; the Dart side
 *   deep-links into the conversation.
 */
object SmsNotifier {
    private const val TAG = "SmsNotifier"
    private const val CHANNEL_ID = "sms_channel"
    private const val DB_NAME = "communication_app.db"

    /** How much of the conversation the expanded notification carries. */
    private const val HISTORY_LINES = 5

    fun notifySms(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        threadId: String,
        subscriptionId: Int = -1,
    ) {
        try {
            // The user is LOOKING at this conversation right now — no
            // notification (Google Messages behavior). Backgrounded app
            // still notifies even for the "open" thread.
            //
            // «Looking at it» means the screen is on AND the phone is unlocked,
            // and both halves are load-bearing. `isResumed` alone is not the
            // question it sounds like: on this device (and on every OEM build
            // that resumes the foreground activity behind the keyguard) waking
            // a locked phone puts MainActivity back into onResume with the lock
            // screen still on top of it. So once the phone had been woken even
            // once, every further message from the last-opened conversation was
            // dropped on the floor — «اگر گوشی لاک باشه نوتیف پیام روی صفحه
            // نمی‌آید». A user who cannot see the screen cannot have read it.
            if (MainActivity.isResumed &&
                MainActivity.visibleThreadId == threadId &&
                isUserWatching(context)
            ) {
                Log.d(TAG, "Suppressed notification for visible thread")
                return
            }

            // The operator's own "you had a missed call" text, for a call this
            // app already put a «تماس بی‌پاسخ» card in the shade for. The
            // message is delivered and stays in the inbox — only the second
            // notification for one event is dropped.
            if (isRedundantMissedCallSms(context, address, body)) {
                Log.d(TAG, "Suppressed carrier missed-call SMS notification")
                return
            }

            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            ensureChannel(nm)

            // ONE notification per conversation, the way Google Messages does
            // it. It used to be one per *message* (id = timestamp), and that is
            // what made the shade's expand chevron useless: each card held a
            // single line with nothing to expand to, while three messages from
            // the same person stacked as three identical cards. The card now
            // carries the last few messages of the thread, so expanding it
            // shows the conversation and the actions.
            val notifId = threadId.hashCode()
            val title = lookupContactName(context, address) ?: address

            // A built-in template arrives as a compact payload; the shade must
            // show the rebuilt message, exactly like the chat does. Display
            // only — nothing that gets written (content://sms, app DB) is
            // touched, and a body that is not a payload comes back unchanged.
            val text = TemplateWire.displayText(body)

            val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra("threadId", threadId)
                }
            val contentIntent = PendingIntent.getActivity(
                context, threadId.hashCode(), launch ?: Intent(), piFlags,
            )

            // Inline reply (RemoteInput requires a MUTABLE PendingIntent on 31+).
            val remoteInput = androidx.core.app.RemoteInput
                .Builder(SmsNotificationActionReceiver.KEY_REPLY_TEXT)
                .setLabel("پاسخ…")
                .build()
            val mutableFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val replyIntent = PendingIntent.getBroadcast(
                context, notifId,
                Intent(SmsNotificationActionReceiver.ACTION_REPLY)
                    .setPackage(context.packageName)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_ADDRESS, address)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_THREAD_ID, threadId)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_NOTIF_ID, notifId)
                    // Reply on the card the message arrived on.
                    .putExtra(
                        SmsNotificationActionReceiver.EXTRA_SUBSCRIPTION_ID,
                        subscriptionId,
                    ),
                mutableFlags,
            )
            val replyAction = NotificationCompat.Action
                .Builder(0, "پاسخ", replyIntent)
                .addRemoteInput(remoteInput)
                .setAllowGeneratedReplies(false)
                .build()

            val markReadIntent = PendingIntent.getBroadcast(
                context, notifId + 1,
                Intent(SmsNotificationActionReceiver.ACTION_MARK_READ)
                    .setPackage(context.packageName)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_THREAD_ID, threadId)
                    .putExtra(SmsNotificationActionReceiver.EXTRA_NOTIF_ID, notifId),
                piFlags,
            )

            // MessagingStyle + Person: the sender's name and contact photo
            // render in the notification exactly like Google Messages.
            // The contact's photo when there is one, and the app's own letter
            // avatar when there is not — never nothing. A card with no large
            // icon falls back to the launcher icon on most OEM shades, which is
            // exactly why a message and a missed call used to look identical
            // there (see [NotificationAvatars]).
            val avatar = lookupContactPhoto(context, address)
                ?: NotificationAvatars.letterAvatar(title, threadId)
            val sender = Person.Builder()
                .setName(title)
                .setKey(threadId)
                .setIcon(IconCompat.createWithBitmap(avatar))
                .build()
            // MessagingStyle needs a "me" even when nothing of the user's is
            // rendered — it is the identity the style is built around.
            val self = Person.Builder().setName("من").setKey("self").build()
            val style = NotificationCompat.MessagingStyle(self)
            // The still-unread messages first, then the one that triggered
            // this. The live receive path posts *before* Dart has persisted the
            // row, so the new message is added by hand and the query drops it
            // if it did land first (see [recentMessages]).
            for (entry in recentMessages(context, threadId, timestamp)) {
                style.addMessage(entry.text, entry.timestamp, sender)
            }
            style.addMessage(text, timestamp, sender)

            // Conversation notification (Android 11+): a long-lived shortcut is
            // what moves the card into the shade's conversation section and
            // gives it the priority/expand treatment a messenger gets. Without
            // a shortcut id the platform ranks it as a plain notification.
            val shortcutId = "thread_$threadId"
            pushConversationShortcut(context, shortcutId, title, sender, threadId)

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_message)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(style)
                .setLargeIcon(avatar)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setCategory(Notification.CATEGORY_MESSAGE)
                // Spelled out rather than left to the platform default: this is
                // what puts the card on the lock screen at all. PRIVATE (not
                // SECRET) is the messenger's setting — the card is always
                // shown, and only its *content* is folded away when the user
                // has asked for sensitive notifications to be hidden.
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setAutoCancel(true)
                .setContentIntent(contentIntent)
                .setShortcutId(shortcutId)
                .setLocusId(LocusIdCompat(shortcutId))
                // Explicit: one notification per conversation must still alert
                // on every new message. The default is already false, but this
                // is the exact behaviour the per-message ids used to buy.
                .setOnlyAlertOnce(false)
                .setWhen(timestamp)
                .setShowWhen(true)
                // «سیم ۲ · ایرانسل» under the sender on a dual-SIM phone —
                // which card took the message is part of reading it. Null on a
                // single-SIM phone (SimRegistry answers null for an unknown or
                // sole subscription), so the shade is unchanged there.
                .apply {
                    if (SimRegistry.isMultiSim(context)) {
                        SimRegistry.labelOf(context, subscriptionId)
                            ?.let { setSubText(it) }
                    }
                }
                .addAction(replyAction)
                .addAction(0, "خواندم", markReadIntent)
                .build()

            // Tagged with the threadId so opening the conversation can dismiss
            // every notification belonging to it (see [cancelThread]).
            nm.notify(threadId, notifId, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post SMS notification: ${e.message}", e)
        }
    }

    /**
     * Whether the screen is on and the phone is unlocked — i.e. whether the
     * user can actually see what the app is showing.
     *
     * Both reads are cheap (no binder round trip beyond the service lookup) and
     * both are needed: an unlocked phone with the display off is not being
     * looked at either, and a phone with no lock set reports `isKeyguardLocked`
     * false even while asleep. Any failure answers **false**, because the cost
     * of guessing wrong is a silently swallowed message.
     */
    private fun isUserWatching(context: Context): Boolean = try {
        val keyguard =
            context.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        val power =
            context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        power.isInteractive && !keyguard.isKeyguardLocked
    } catch (e: Exception) {
        Log.w(TAG, "isUserWatching failed: ${e.message}")
        false
    }

    /** Dismisses every posted SMS notification tagged with [threadId]. */
    fun cancelThread(context: Context, threadId: String) {
        try {
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                nm.activeNotifications
                    .filter { it.tag == threadId }
                    .forEach { nm.cancel(it.tag, it.id) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "cancelThread failed: ${e.message}")
        }
    }

    private fun ensureChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "پیام‌های کوتاه", NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "اعلان‌های پیام‌های کوتاه دریافتی"
                    enableVibration(true)
                    enableLights(true)
                },
            )
        }
    }

    /** One unread message, as the shade renders it. */
    private data class Line(val text: String, val timestamp: Long)

    /**
     * Whether this message is the carrier telling the user about a missed call
     * this app has **already** announced itself.
     *
     * Three conditions, all required, because the cost of a false positive is a
     * silently swallowed notification:
     *
     *  1. the sender is not a phone number (`MissedCalls`, `Irancell`, …) — a
     *     person's text is never suppressed, whatever it says;
     *  2. the body names a number this app posted «تماس بی‌پاسخ» for in the
     *     last half hour ([CallInCallService.wasMissedRecently]); and
     *  3. it reads like a missed-call report («تماس» plus a count, or the
     *     English wording some operators use).
     *
     * Without (2) this would be a guess about somebody else's SMS format; with
     * it, the app is only declining to say twice what it just said.
     */
    private fun isRedundantMissedCallSms(
        context: Context,
        address: String,
        body: String,
    ): Boolean {
        // (1) A real caller's address is dialable; a service sender is not.
        if (address.any { it.isDigit() } && address.none { it.isLetter() }) return false
        // (3) Cheapest test first — most service messages are not about calls.
        val says = body.contains("تماس") || body.contains("missed", ignoreCase = true)
        if (!says) return false
        // (2) Any number in the body that we just reported as missed.
        return NUMBER_IN_BODY.findAll(body).any { m ->
            CallInCallService.wasMissedRecently(context, m.value)
        }
    }

    /** Runs of digits long enough to be a phone number, in any body. */
    private val NUMBER_IN_BODY = Regex("[0-9\\u06F0-\\u06F9]{7,15}")

    /**
     * The **unread received** messages of [threadId], oldest first, so the
     * expanded notification stacks the messages still waiting for an answer.
     *
     * Only unread, and only incoming: a notification is a list of what the user
     * has not seen yet, not a transcript. The first version replayed the last
     * five rows of any type, so opening the shade showed the user their own
     * replies and messages they had already read — Google Messages stacks the
     * pending ones and nothing else.
     *
     * Read straight from the app's SQLite file — the same access the quick
     * reply already uses — because this runs with the Flutter engine dead as
     * often as not. A missing or locked database simply yields no history: the
     * notification is still posted with the message that just arrived.
     *
     * [excludeTimestamp] drops the row for the message being notified about, so
     * it is not rendered twice when Dart happened to persist it first.
     */
    private fun recentMessages(
        context: Context,
        threadId: String,
        excludeTimestamp: Long,
    ): List<Line> {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) return emptyList()
        return try {
            android.database.sqlite.SQLiteDatabase.openDatabase(
                dbFile.path,
                null,
                android.database.sqlite.SQLiteDatabase.OPEN_READONLY,
            ).use { db ->
                val out = ArrayList<Line>()
                db.rawQuery(
                    "SELECT body, timestamp FROM messages " +
                        "WHERE thread_id = ? AND is_deleted = 0 AND timestamp <> ? " +
                        "AND type = 'received' AND is_read = 0 " +
                        "ORDER BY timestamp DESC LIMIT ?",
                    arrayOf(threadId, excludeTimestamp.toString(), "$HISTORY_LINES"),
                ).use { c ->
                    while (c.moveToNext()) {
                        out.add(
                            Line(
                                // A compact template payload has to be rebuilt
                                // here too — the shade must read like the chat.
                                text = TemplateWire.displayText(c.getString(0) ?: ""),
                                timestamp = c.getLong(1),
                            ),
                        )
                    }
                }
                out.reversed()
            }
        } catch (e: Exception) {
            Log.d(TAG, "history read skipped: ${e.message}")
            emptyList()
        }
    }

    /**
     * Publishes the long-lived shortcut a conversation notification needs.
     *
     * Best-effort: a device that refuses (shortcut limit reached, an OEM
     * launcher that rejects the push) still gets the notification, only ranked
     * as an ordinary one.
     */
    private fun pushConversationShortcut(
        context: Context,
        shortcutId: String,
        title: String,
        person: Person,
        threadId: String,
    ) {
        try {
            val open = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    action = Intent.ACTION_VIEW
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra("threadId", threadId)
                } ?: return
            val shortcut = ShortcutInfoCompat.Builder(context, shortcutId)
                .setShortLabel(title)
                .setLongLived(true)
                .setPerson(person)
                .setIntent(open)
                .setIcon(IconCompat.createWithResource(context, context.applicationInfo.icon))
                .build()
            ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
        } catch (e: Exception) {
            Log.d(TAG, "shortcut push skipped: ${e.message}")
        }
    }

    /** The contact's photo thumbnail (round-cropped by the system), or null. */
    private fun lookupContactPhoto(context: Context, phone: String): Bitmap? {
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phone),
            )
            val photoUri = context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.PHOTO_THUMBNAIL_URI),
                null, null, null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                ?: return null
            context.contentResolver.openInputStream(Uri.parse(photoUri))?.use {
                BitmapFactory.decodeStream(it)
            }
        } catch (e: Exception) {
            null
        }
    }

    fun lookupContactName(context: Context, phone: String): String? {
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phone),
            )
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (e: SecurityException) {
            null // READ_CONTACTS not granted
        } catch (e: Exception) {
            null
        }
    }
}
