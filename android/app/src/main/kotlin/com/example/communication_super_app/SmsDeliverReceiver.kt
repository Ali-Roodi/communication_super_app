package com.example.communication_super_app

import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * Receives `SMS_DELIVER` — the ordered broadcast Android sends **only to the
 * default SMS app**. When this app holds the SMS role, the system no longer
 * writes incoming messages into `content://sms`; the default app must do it,
 * otherwise the message exists nowhere except our private DB and every other
 * SMS app on the phone stays blind.
 *
 * Responsibility split (important — avoids double handling):
 * - THIS receiver: writes the incoming message into the device SMS provider.
 * - `SmsHandler` (dynamic) / `IncomingSmsReceiver` (manifest, cold start):
 *   keep listening to the non-ordered `SMS_RECEIVED` broadcast, which the
 *   system still sends after `SMS_DELIVER`, and handle the app-side persist +
 *   notification + UI refresh exactly as before.
 */
class SmsDeliverReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "SmsDeliverReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return

        val app = context.applicationContext
        val pending = goAsync()
        Thread {
            try {
                writeToProvider(app, intent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to write incoming SMS to provider: ${e.message}", e)
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun writeToProvider(context: Context, intent: Intent) {
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (parts.isEmpty()) return

        val address = parts[0].originatingAddress ?: return
        val body = parts.joinToString("") { it.messageBody ?: "" }
        val timestamp = parts[0].timestampMillis

        // Blocked sender: as the default SMS app WE decide what lands in the
        // provider — a blocked message lands nowhere.
        if (BlockedNumbers.isBlocked(context, address)) {
            Log.d(TAG, "Blocked SMS not written to provider")
            return
        }

        // Which SIM took the message. The broadcast carries it as the
        // "subscription" extra; every other SMS app reads the provider column,
        // so an unstamped row loses the SIM for the whole phone, not just us.
        val subscriptionId = if (
            android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP_MR1
        ) {
            intent.getIntExtra("subscription", -1)
        } else {
            -1
        }

        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, timestamp)
            put(Telephony.Sms.READ, 0)
            put(Telephony.Sms.SEEN, 0)
            if (subscriptionId != -1) {
                put(Telephony.Sms.SUBSCRIPTION_ID, subscriptionId)
            }
        }
        val uri = context.contentResolver.insert(Telephony.Sms.Inbox.CONTENT_URI, values)
        Log.d(TAG, "Incoming SMS stored in provider: $uri")
    }
}
