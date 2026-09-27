package com.example.communication_super_app.smscrypto

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.communication_super_app.R

/**
 * Where an encrypted SMS (`#E:` — [Wire.looksEncrypted]) goes when it arrives:
 * **not** into `content://sms`, **not** into the app's `messages` table, and
 * with **no** sender or text in the notification (owner's decisions,
 * 1405/07/05; matrix rows 11 and 22).
 *
 * The receivers run while the app is dead and the secure section is locked,
 * so nothing here can decrypt. The packet is parked, as the ciphertext it is,
 * in `secure_queue` of the main database; the Dart side drains that queue into
 * the secure section the next time it is open (`SecureMessenger`). What sits in
 * the queue in the clear is only what the SMS itself already exposed to the
 * carrier: the sender's number, the time, and ciphertext.
 *
 * The notification is one generic card, «پیام رمز جدید», with a bare id (no
 * tag), so `SmsNotifier.reconcile` — which owns every *tagged* card — never
 * mistakes it for a conversation's.
 */
object SecureSmsInbox {
    private const val TAG = "SecureSmsInbox"
    private const val DB_NAME = "communication_app.db"
    private const val CHANNEL_ID = "secure_sms"
    const val NOTIFICATION_ID = 0x5EC0

    /** Set on the launch intent of the card; `MainActivity` turns it into a `secure` launch action. */
    const val EXTRA_OPEN_SECURE = "open_secure_inbox"

    /**
     * MIRRORED in `DatabaseHelper` (v25) and `AppConstants.secureQueueTable`.
     * Created here too, `IF NOT EXISTS`, because an SMS can arrive after an
     * update and before the app was ever opened to run the migration — and a
     * missing table would lose the message.
     */
    private const val DDL = """
        CREATE TABLE IF NOT EXISTS secure_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          address TEXT NOT NULL,
          body TEXT NOT NULL,
          timestamp INTEGER NOT NULL,
          subscription_id INTEGER,
          received_at INTEGER NOT NULL,
          UNIQUE (address, body)
        )
    """

    fun isEncrypted(body: String): Boolean = Wire.looksEncrypted(body)

    /**
     * Parks one received packet. A carrier that delivers the same SMS twice
     * adds nothing (UNIQUE address+body). False only when the database could
     * not be written at all.
     */
    fun enqueue(context: Context, address: String, body: String, timestamp: Long, subscriptionId: Int): Boolean {
        val dbFile = context.getDatabasePath(DB_NAME)
        dbFile.parentFile?.mkdirs()
        repeat(3) { attempt ->
            try {
                SQLiteDatabase.openOrCreateDatabase(dbFile, null).use { db ->
                    db.execSQL(DDL)
                    val values = ContentValues().apply {
                        put("address", address)
                        put("body", body)
                        put("timestamp", timestamp)
                        if (subscriptionId >= 0) put("subscription_id", subscriptionId)
                        put("received_at", System.currentTimeMillis())
                    }
                    db.insertWithOnConflict("secure_queue", null, values, SQLiteDatabase.CONFLICT_IGNORE)
                }
                return true
            } catch (e: Exception) {
                Log.w(TAG, "Queueing an encrypted SMS failed (attempt ${attempt + 1}): ${e.javaClass.simpleName}")
                if (attempt < 2) Thread.sleep(150)
            }
        }
        return false
    }

    /** How many packets wait in the queue (for the card's count). */
    private fun pending(context: Context): Int = try {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) {
            0
        } else {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery("SELECT COUNT(*) FROM secure_queue", null).use { c ->
                    if (c.moveToFirst()) c.getInt(0) else 0
                }
            }
        }
    } catch (e: Exception) {
        0
    }

    /**
     * Posts (or refreshes) «پیام رمز جدید». Handshake packets are queued too
     * but are not messages, so the caller decides whether to notify.
     */
    fun notifyArrived(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "پیام‌های رمز", NotificationManager.IMPORTANCE_HIGH).apply {
                        description = "اعلان رسیدن پیام رمز، بدون نام فرستنده و متن"
                        // Nothing about an encrypted message on the lock screen.
                        lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
                    },
                )
            }
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_OPEN_SECURE, true)
            }
            val count = pending(context).coerceAtLeast(1)
            val text = if (count > 1) "${persianDigits(count)} پیام رمز جدید" else "پیام رمز جدید"
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_message)
                .setContentTitle(text)
                .setContentText("برای خواندن، بخش امن را باز کنید")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(
                    NotificationCompat.Builder(context, CHANNEL_ID)
                        .setSmallIcon(R.drawable.ic_stat_message)
                        .setContentTitle("پیام جدید")
                        .build(),
                )
                .setNumber(count)
                .setOnlyAlertOnce(false)
                .setAutoCancel(true)
                .setContentIntent(PendingIntent.getActivity(context, NOTIFICATION_ID, launch ?: Intent(), flags))
                .build()
            nm.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Posting the encrypted-SMS card failed: ${e.javaClass.simpleName}")
        }
    }

    fun cancelNotification(context: Context) {
        try {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(NOTIFICATION_ID)
        } catch (e: Exception) {
            // Nothing to cancel.
        }
    }

    private fun persianDigits(n: Int): String =
        n.toString().map { c -> if (c in '0'..'9') '۰' + (c - '0') else c }.joinToString("")

    /**
     * Whether [body] should announce itself: a message to read — not a
     * handshake packet and not a receipt ([Wire.TYPE_CONTROL]).
     */
    fun announces(body: String): Boolean = try {
        (Wire.parse(body) as? Packet.Message)?.control == false
    } catch (e: SmsCryptoException) {
        false
    }
}
