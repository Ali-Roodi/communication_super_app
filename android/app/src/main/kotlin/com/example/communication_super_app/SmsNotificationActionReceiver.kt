package com.example.communication_super_app

import android.app.NotificationManager
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import com.example.communication_super_app.sim.SimRegistry
import java.util.UUID

/**
 * Handles the actions on the cold-start SMS notification (posted by
 * [IncomingSmsReceiver] while the app process is dead):
 *
 * - **پاسخ** (inline RemoteInput): sends the reply with [SmsManager], writes it
 *   through to the SMS provider (default-app duty) and into the app DB, so the
 *   conversation is already correct when the app next opens.
 * - **خواندم**: marks the thread read in the app DB.
 * - **مسدودسازی**: adds the sender to `blocked_numbers`, with a short-lived
 *   «لغو» card in place of the message.
 *
 * All of them dismiss the notification. If the Flutter engine happens to be alive the
 * next mirror-sync/LoadThreads reconciles state — these writes are the same
 * shape the app itself produces.
 */
class SmsNotificationActionReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "SmsNotifAction"
        private const val DB_NAME = "communication_app.db"
        const val ACTION_REPLY = "com.example.communication_super_app.SMS_REPLY"
        const val ACTION_MARK_READ = "com.example.communication_super_app.SMS_MARK_READ"
        const val ACTION_BLOCK = "com.example.communication_super_app.SMS_BLOCK"
        const val ACTION_UNDO_BLOCK = "com.example.communication_super_app.SMS_UNDO_BLOCK"
        const val EXTRA_ADDRESS = "address"

        /** The `blocked_numbers.id` a block from the shade inserted — what its
         *  «لغو» removes. Absent when the sender was already blocked. */
        const val EXTRA_BLOCKED_ROW_ID = "blocked_row_id"

        /** A write the app's own connection is holding up is retried this many
         *  times, [DB_RETRY_DELAY_MS] apart, before it is given up on. */
        private const val DB_ATTEMPTS = 4
        private const val DB_RETRY_DELAY_MS = 750L
        const val EXTRA_THREAD_ID = "thread_id"
        const val EXTRA_NOTIF_ID = "notif_id"

        /** SIM the incoming message arrived on — the reply goes out on it. */
        const val EXTRA_SUBSCRIPTION_ID = "subscription_id"
        const val KEY_REPLY_TEXT = "key_reply_text"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val pending = goAsync()
        Thread {
            try {
                when (intent.action) {
                    ACTION_REPLY -> handleReply(app, intent)
                    ACTION_MARK_READ -> handleMarkRead(app, intent)
                    ACTION_BLOCK -> handleBlock(app, intent)
                    ACTION_UNDO_BLOCK -> handleUndoBlock(app, intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Notification action failed: ${e.message}", e)
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun handleReply(context: Context, intent: Intent) {
        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(KEY_REPLY_TEXT)?.toString()?.trim()
        val address = intent.getStringExtra(EXTRA_ADDRESS)
        val threadId = intent.getStringExtra(EXTRA_THREAD_ID)
        if (text.isNullOrEmpty() || address.isNullOrEmpty() || threadId == null) {
            dismiss(context, intent)
            return
        }

        // 1. Send — on the SIM the message came in on. Answering a work
        //    number from the personal card because the shade forgot which one
        //    it was is exactly the mistake dual-SIM support exists to prevent.
        //    -1 (unknown SIM, or a phone with one) falls back to the default.
        val requestedSubId = intent.getIntExtra(EXTRA_SUBSCRIPTION_ID, -1)
        val subscriptionId = if (requestedSubId >= 0) {
            requestedSubId
        } else {
            SimRegistry.defaultSmsSubscriptionId()
        }
        @Suppress("DEPRECATION")
        val base = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            SmsManager.getDefault()
        }
        val sm = if (
            subscriptionId >= 0 &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1
        ) {
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    base.createForSubscriptionId(subscriptionId)
                } else {
                    @Suppress("DEPRECATION")
                    SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
                }
            }.getOrDefault(base)
        } else {
            base
        }
        val parts = sm.divideMessage(text)
        if (parts.size == 1) {
            sm.sendTextMessage(address, null, text, null, null)
        } else {
            sm.sendMultipartTextMessage(address, null, parts, null, null)
        }
        val now = System.currentTimeMillis()

        // 2. Provider write-through (default-SMS-app duty).
        var deviceId: Long? = null
        if (Telephony.Sms.getDefaultSmsPackage(context) == context.packageName) {
            try {
                val values = ContentValues().apply {
                    put(Telephony.Sms.ADDRESS, address)
                    put(Telephony.Sms.BODY, text)
                    put(Telephony.Sms.DATE, now)
                    put(Telephony.Sms.READ, 1)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1 &&
                        subscriptionId >= 0
                    ) {
                        put(Telephony.Sms.SUBSCRIPTION_ID, subscriptionId)
                    }
                }
                deviceId = context.contentResolver
                    .insert(Telephony.Sms.Sent.CONTENT_URI, values)
                    ?.lastPathSegment?.toLongOrNull()
            } catch (e: Exception) {
                Log.e(TAG, "Provider write failed: ${e.message}")
            }
        }

        // 3. App DB: sent message + thread read (replying implies read).
        //    The SMS is already out: whatever happens here the card must go,
        //    or the user reads a card still standing as "not sent" and sends
        //    the same message a second time. A row that never lands is picked
        //    up from the provider by the next mirror-sync.
        withDbRetry(context) { db ->
            val values = ContentValues().apply {
                put("id", UUID.randomUUID().toString())
                put("thread_id", threadId)
                putNull("contact_id")
                put("phone_number", address)
                put("body", text)
                put("type", "sent")
                put("status", "sent")
                put("timestamp", now)
                put("is_read", 1)
                if (deviceId != null) put("device_sms_id", deviceId)
                if (subscriptionId >= 0) put("subscription_id", subscriptionId)
            }
            db.insertWithOnConflict(
                "messages", null, values, SQLiteDatabase.CONFLICT_IGNORE,
            )
            db.execSQL(
                "UPDATE messages SET is_read = 1 " +
                    "WHERE thread_id = ? AND type = 'received' AND is_read = 0",
                arrayOf(threadId),
            )
        }
        Log.d(TAG, "Notification reply sent")
        dismiss(context, intent)
        MainActivity.notifyThreadChanged(threadId)
    }

    /**
     * «خواندم».
     *
     * **The card goes first, whatever the database does.** It used to be
     * dismissed only after the UPDATE, and an UPDATE that threw — the app's
     * own connection holding the write lock past the busy timeout, which is
     * exactly what a mirror-sync or an import does for seconds at a time —
     * skipped the dismiss: the button was pressed and nothing happened.
     * That is the reported «بعضی اوقات دکمه خواندم کار نمی‌کند». The write is
     * still retried, and a failure leaves the message unread in the inbox,
     * which is where the user will find it; a notification that refuses to
     * go away is the one outcome that must not happen.
     *
     * Then the running app, if there is one, is told: its inbox was painted
     * from rows this just changed, and without a nudge it went on showing the
     * conversation bold until the next resume.
     */
    private fun handleMarkRead(context: Context, intent: Intent) {
        val threadId = intent.getStringExtra(EXTRA_THREAD_ID)
        dismiss(context, intent)
        if (threadId == null) return
        val done = withDbRetry(context) { db ->
            db.execSQL(
                "UPDATE messages SET is_read = 1 " +
                    "WHERE thread_id = ? AND type = 'received' AND is_read = 0",
                arrayOf(threadId),
            )
        }
        if (!done) Log.w(TAG, "Mark-read not written; the thread stays unread")
        MainActivity.notifyThreadChanged(threadId)
    }

    /**
     * «مسدودسازی» — the sender goes into «مسدودشده‌ها», straight from the shade.
     *
     * The row is the one `BlockedNumbersRepository.block` writes — keyed by
     * the canonical thread id, which is what every check (Dart,
     * [BlockedNumbers.isBlocked], `CallInCallService`) looks up — and only the
     * four base columns are named, so a database an older build left behind
     * (before `is_spam` existed) takes it too. Blocking a sender who is
     * already blocked adds nothing, and its undo must then remove nothing.
     *
     * A block is not something to do on a slip of the thumb, so the card is
     * replaced by a silent «… مسدود شد» with «لغو» for a few seconds rather than
     * just vanishing — a mis-tap is one more tap away from undone.
     */
    private fun handleBlock(context: Context, intent: Intent) {
        val threadId = intent.getStringExtra(EXTRA_THREAD_ID)
        val address = intent.getStringExtra(EXTRA_ADDRESS)
        if (threadId.isNullOrEmpty() || address.isNullOrEmpty()) {
            dismiss(context, intent)
            return
        }
        var insertedId: String? = null
        val done = withDbRetry(context) { db ->
            val exists = db.rawQuery(
                "SELECT 1 FROM blocked_numbers WHERE normalized = ? LIMIT 1",
                arrayOf(threadId),
            ).use { it.moveToFirst() }
            if (!exists) {
                val id = UUID.randomUUID().toString()
                val row = db.insertWithOnConflict(
                    "blocked_numbers",
                    null,
                    ContentValues().apply {
                        put("id", id)
                        put("phone_number", address)
                        put("normalized", threadId)
                        put("created_at", System.currentTimeMillis())
                    },
                    SQLiteDatabase.CONFLICT_IGNORE,
                )
                if (row != -1L) insertedId = id
            }
        }
        dismiss(context, intent)
        if (!done) {
            // Nothing was written: say so rather than pretend. The card is
            // gone, so the user is not left pressing a button that did nothing
            // twice, and the message is still in the inbox to block from there.
            SmsNotifier.notifyBlockFailed(context, threadId, address)
            return
        }
        SmsNotifier.notifyBlocked(context, threadId, address, insertedId)
        MainActivity.notifyThreadChanged(threadId)
    }

    /** «لغو» on the «… مسدود شد» card: removes exactly the row the block added. */
    private fun handleUndoBlock(context: Context, intent: Intent) {
        val threadId = intent.getStringExtra(EXTRA_THREAD_ID)
        val blockedRowId = intent.getStringExtra(EXTRA_BLOCKED_ROW_ID)
        if (threadId != null) SmsNotifier.cancelThread(context, threadId)
        if (blockedRowId.isNullOrEmpty()) return
        withDbRetry(context) { db ->
            db.delete("blocked_numbers", "id = ?", arrayOf(blockedRowId))
        }
        if (threadId != null) MainActivity.notifyThreadChanged(threadId)
    }

    /**
     * Runs [block] on a writable connection, retrying a few times when the
     * database is busy. True when it completed; false when it never did
     * (missing database, or still locked after the retries).
     */
    private fun withDbRetry(context: Context, block: (SQLiteDatabase) -> Unit): Boolean {
        repeat(DB_ATTEMPTS) { attempt ->
            try {
                val db = openDb(context) ?: return false
                db.use(block)
                return true
            } catch (e: Exception) {
                Log.w(TAG, "DB write attempt ${attempt + 1} failed: ${e.message}")
                if (attempt < DB_ATTEMPTS - 1) Thread.sleep(DB_RETRY_DELAY_MS)
            }
        }
        return false
    }

    private fun dismiss(context: Context, intent: Intent) {
        // Notifications are posted with the threadId as TAG (see SmsNotifier),
        // so a tag-less cancel(id) would be a silent no-op. Cancel every
        // notification of the thread — mark-read/reply applies to all of them.
        val threadId = intent.getStringExtra(EXTRA_THREAD_ID)
        if (threadId != null) SmsNotifier.cancelThread(context, threadId)
        val id = intent.getIntExtra(EXTRA_NOTIF_ID, -1)
        if (id != -1) {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(threadId, id)
        }
    }

    private fun openDb(context: Context): SQLiteDatabase? {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) return null
        return try {
            SQLiteDatabase.openDatabase(
                dbFile.path, null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING,
            ).apply {
                rawQuery("PRAGMA busy_timeout = 5000", null).use { it.moveToFirst() }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Open DB failed: ${e.message}")
            null
        }
    }
}
