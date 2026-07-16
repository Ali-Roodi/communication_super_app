package com.example.communication_super_app

import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.provider.Telephony
import android.util.Log
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

        // Blocked sender: drop silently — no persist, no notification.
        if (BlockedNumbers.isBlocked(context, address)) {
            Log.d(TAG, "Dropped background SMS from blocked number")
            return
        }

        persist(context, address, body, timestamp, threadId)
        SmsNotifier.notifySms(context, address, body, timestamp, threadId)
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

}
