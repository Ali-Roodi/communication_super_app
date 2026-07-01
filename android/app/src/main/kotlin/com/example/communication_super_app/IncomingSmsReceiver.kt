package com.example.communication_super_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Telephony
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.UUID

/**
 * Manifest-registered receiver that delivers incoming SMS **when the app
 * process is not alive** (cold start). It persists the message straight into
 * the sqflite DB and posts a notification natively — no Flutter engine needed.
 *
 * When the app IS alive, its dynamic receiver (`SmsHandler`) + the Flutter
 * pipeline already persist + notify + update the UI, so this receiver bails out
 * early (guarded by [SmsHandler.isDynamicReceiverActive]) to avoid duplicates.
 *
 * IMPORTANT: the table/column names and the enum string values here MUST match
 * the Dart side (`messages` table, `MessageType.received` → "received",
 * `MessageStatus.delivered` → "delivered"). The thread-id normalization mirrors
 * `PhoneNormalizer.toThreadId`.
 */
class IncomingSmsReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "IncomingSmsReceiver"
        private const val DB_NAME = "communication_app.db"
        private const val CHANNEL_ID = "sms_channel"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        // The live app (foreground or background-but-alive) handles SMS through
        // its dynamic receiver + Flutter; don't double-persist/notify.
        if (SmsHandler.isDynamicReceiverActive) return

        val app = context.applicationContext
        val pending = goAsync()
        Thread {
            try {
                handle(app, intent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to handle incoming SMS: ${e.message}", e)
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun handle(context: Context, intent: Intent) {
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (parts.isEmpty()) return

        val address = parts[0].originatingAddress ?: return
        val body = parts.joinToString("") { it.messageBody ?: "" }
        val timestamp = parts[0].timestampMillis
        val threadId = normalizeToThreadId(address)

        persist(context, address, body, timestamp, threadId)

        val name = lookupContactName(context, address)
        notify(context, name ?: address, body, threadId)
        Log.d(TAG, "Delivered background SMS from $address")
    }

    // ── Persist (mirrors MessageRepository.createMessage) ─────────────────────

    private fun persist(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        threadId: String,
    ) {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) return // DB is created on first app launch
        val db = try {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READWRITE)
        } catch (e: Exception) {
            Log.e(TAG, "Open DB failed: ${e.message}")
            return
        }
        try {
            val values = ContentValues().apply {
                put("id", UUID.randomUUID().toString())
                put("thread_id", threadId)
                putNull("contact_id")
                put("phone_number", address)
                put("body", body)
                put("type", "received")
                put("status", "delivered")
                put("timestamp", timestamp)
                put("is_read", 0)
            }
            // OR IGNORE: the unique (phone_number, body, timestamp, type) index
            // dedups against a later device-inbox import.
            db.insertWithOnConflict(
                "messages", null, values, SQLiteDatabase.CONFLICT_IGNORE,
            )
        } finally {
            db.close()
        }
    }

    /// Mirrors PhoneNormalizer.toThreadId (national 09xxxxxxxxx form).
    private fun normalizeToThreadId(phone: String): String {
        val digits = phone.filter { it.isDigit() }
        if (digits.isEmpty()) return phone.trim()
        val d = if (digits.startsWith("0098")) digits.substring(2) else digits
        return when {
            d.length == 12 && d.startsWith("98") -> "0" + d.substring(2)
            d.length == 11 && d.startsWith("0") -> d
            d.length == 10 && d.startsWith("9") -> "0$d"
            else -> d
        }
    }

    // ── Contact name (ContactsContract PhoneLookup) ───────────────────────────

    private fun lookupContactName(context: Context, phone: String): String? {
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

    // ── Notification ──────────────────────────────────────────────────────────

    private fun notify(context: Context, title: String, body: String, threadId: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "پیام‌های کوتاه", NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = "اعلان‌های پیام‌های کوتاه دریافتی" }
            nm.createNotificationChannel(channel)
        }

        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("threadId", threadId)
            }
        val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = PendingIntent.getActivity(
            context, threadId.hashCode(), launch ?: Intent(), piFlags,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()

        nm.notify(threadId.hashCode(), notification)
    }
}
