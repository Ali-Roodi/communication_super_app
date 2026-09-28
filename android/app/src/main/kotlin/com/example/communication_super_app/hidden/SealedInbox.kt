package com.example.communication_super_app.hidden

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import com.example.communication_super_app.smscrypto.SealedBox
import java.security.SecureRandom
import org.json.JSONObject

/**
 * Where Kotlin writes down what happened with a hidden number while the
 * secure section was locked: a call, an SMS. Each record is sealed to the
 * section's public key ([SealedBox]) and parked in `sealed_queue` of the main
 * database; Dart opens and drains it into `secure.db` on the next unlock.
 *
 * Only `kind` (`call` / `sms`) is in the clear — it decides which side of the
 * app drains the row, and a hidden call or SMS is already announced by its
 * notification. The number, the time and the text are inside the blob.
 *
 * Records are JSON:
 * - `{k: "sms", address, body, timestamp, subscriptionId}` — plain or `#E:`
 * - `{k: "call", number, type, date, duration, account}` — a call-log row
 *   (`type` is the raw `CallLog.Calls.TYPE`, mapped in Dart like the mirror)
 */
object SealedInbox {
    private const val TAG = "SealedInbox"
    private const val DB_NAME = "communication_app.db"
    private val random = SecureRandom()

    /**
     * MIRRORED in `DatabaseHelper._createSealedQueueTable` (v26) and
     * `AppConstants.sealedQueueTable`. Created here too, `IF NOT EXISTS`: a
     * call can end after an update and before the app ran its migration.
     */
    private const val DDL = """
        CREATE TABLE IF NOT EXISTS sealed_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          kind TEXT NOT NULL,
          blob BLOB NOT NULL,
          created_at INTEGER NOT NULL
        )
    """

    const val KIND_SMS = "sms"
    const val KIND_CALL = "call"

    /**
     * Seals [record] and parks it. False when there is no sealing key (the
     * section has never been opened on this build) or nothing could be
     * written — the caller then falls back rather than lose the record.
     */
    fun enqueue(context: Context, kind: String, record: JSONObject): Boolean {
        val key = HiddenNumbers.sealingKey(context) ?: return false
        val blob = try {
            SealedBox.seal(key, record.toString().toByteArray(Charsets.UTF_8), random)
        } catch (e: Exception) {
            Log.e(TAG, "Sealing failed: ${e.javaClass.simpleName}")
            return false
        }
        val dbFile = context.getDatabasePath(DB_NAME)
        dbFile.parentFile?.mkdirs()
        repeat(3) { attempt ->
            try {
                SQLiteDatabase.openOrCreateDatabase(dbFile, null).use { db ->
                    db.execSQL(DDL)
                    db.insertOrThrow(
                        "sealed_queue",
                        null,
                        ContentValues().apply {
                            put("kind", kind)
                            put("blob", blob)
                            put("created_at", System.currentTimeMillis())
                        },
                    )
                }
                return true
            } catch (e: Exception) {
                Log.w(TAG, "Parking a sealed record failed (attempt ${attempt + 1}): ${e.javaClass.simpleName}")
                if (attempt < 2) Thread.sleep(150)
            }
        }
        return false
    }

    /** How many sealed SMS wait (for the «پیام رمز جدید» count). */
    fun pendingSms(context: Context): Int = try {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) {
            0
        } else {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery(
                    "SELECT COUNT(*) FROM sealed_queue WHERE kind = ?",
                    arrayOf(KIND_SMS),
                ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }
            }
        }
    } catch (e: Exception) {
        0 // no table yet
    }
}
