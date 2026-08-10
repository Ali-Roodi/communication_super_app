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
 *
 * Both dismiss the notification. If the Flutter engine happens to be alive the
 * next mirror-sync/LoadThreads reconciles state — these writes are the same
 * shape the app itself produces.
 */
class SmsNotificationActionReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "SmsNotifAction"
        private const val DB_NAME = "communication_app.db"
        const val ACTION_REPLY = "com.example.communication_super_app.SMS_REPLY"
        const val ACTION_MARK_READ = "com.example.communication_super_app.SMS_MARK_READ"
        const val EXTRA_ADDRESS = "address"
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
        openDb(context)?.use { db ->
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
        Log.d(TAG, "Notification reply sent to $address")
        dismiss(context, intent)
    }

    private fun handleMarkRead(context: Context, intent: Intent) {
        val threadId = intent.getStringExtra(EXTRA_THREAD_ID) ?: return
        openDb(context)?.use { db ->
            db.execSQL(
                "UPDATE messages SET is_read = 1 " +
                    "WHERE thread_id = ? AND type = 'received' AND is_read = 0",
                arrayOf(threadId),
            )
        }
        dismiss(context, intent)
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
