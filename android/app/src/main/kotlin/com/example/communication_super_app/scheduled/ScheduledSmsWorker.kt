package com.example.communication_super_app.scheduled

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.telephony.SmsManager
import android.util.Log
import java.util.Calendar

/**
 * Headless delivery of due scheduled messages (PHASE 2).
 *
 * Runs from an AlarmManager broadcast even when the Flutter engine is not
 * alive. It opens the same `sqflite` database directly, finds every pending
 * message whose time has arrived, sends it with [SmsManager], and advances the
 * row (recurrence) or completes it.
 *
 * IMPORTANT: the table/column names, the enum string values and the recurrence
 * logic here MUST stay in sync with the Dart side
 * (`AppConstants.scheduledMessagesTable`, `ScheduledMessage`,
 * `scheduled_message_model.dart`). Keep the two in lock-step when either
 * changes.
 */
object ScheduledSmsWorker {
    private const val TAG = "ScheduledSmsWorker"
    private const val DB_NAME = "communication_app.db"
    private const val TABLE = "scheduled_messages"

    /** Sends every due message and updates its row. Safe to call repeatedly. */
    fun processDue(context: Context) {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) return

        val db = try {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READWRITE)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open DB: ${e.message}")
            return
        }

        try {
            val now = System.currentTimeMillis()
            val due = queryDue(db, now)
            Log.d(TAG, "Processing ${due.size} due scheduled message(s)")
            for (row in due) {
                val sent = sendSms(context, row.phoneNumber, row.body)
                db.update(TABLE, advance(row, sent), "id = ?", arrayOf(row.id))
            }
        } catch (e: Exception) {
            Log.e(TAG, "processDue failed: ${e.message}", e)
        } finally {
            db.close()
        }
    }

    /** Epoch millis of the soonest pending message, or null if none. */
    fun earliestPending(context: Context): Long? {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) return null
        val db = try {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY)
        } catch (e: Exception) {
            return null
        }
        return try {
            db.rawQuery(
                "SELECT MIN(scheduled_at) FROM $TABLE WHERE status = 'pending'",
                null
            ).use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null }
        } catch (e: Exception) {
            null
        } finally {
            db.close()
        }
    }

    // ── Query ────────────────────────────────────────────────────────────────

    private data class Row(
        val id: String,
        val phoneNumber: String,
        val body: String,
        val scheduledAt: Long,
        val repeat: String,
        val repeatEvery: Int,
        val weekdays: Set<Int>,
        val endType: String,
        val endDate: Long?,
        val maxOccurrences: Int?,
        val occurrenceCount: Int,
    )

    private fun queryDue(db: SQLiteDatabase, now: Long): List<Row> {
        val out = mutableListOf<Row>()
        db.query(
            TABLE,
            null,
            "status = ? AND scheduled_at <= ?",
            arrayOf("pending", now.toString()),
            null,
            null,
            "scheduled_at ASC",
        ).use { c ->
            while (c.moveToNext()) out.add(readRow(c))
        }
        return out
    }

    private fun readRow(c: Cursor): Row {
        fun str(name: String) = c.getString(c.getColumnIndexOrThrow(name))
        fun strOrNull(name: String): String? {
            val i = c.getColumnIndexOrThrow(name)
            return if (c.isNull(i)) null else c.getString(i)
        }
        fun longOrNull(name: String): Long? {
            val i = c.getColumnIndexOrThrow(name)
            return if (c.isNull(i)) null else c.getLong(i)
        }
        fun intOrNull(name: String): Int? {
            val i = c.getColumnIndexOrThrow(name)
            return if (c.isNull(i)) null else c.getInt(i)
        }
        return Row(
            id = str("id"),
            phoneNumber = str("phone_number"),
            body = str("body"),
            scheduledAt = c.getLong(c.getColumnIndexOrThrow("scheduled_at")),
            repeat = strOrNull("repeat") ?: "none",
            repeatEvery = intOrNull("repeat_every") ?: 1,
            weekdays = parseWeekdays(strOrNull("weekdays")),
            endType = strOrNull("end_type") ?: "never",
            endDate = longOrNull("end_date"),
            maxOccurrences = intOrNull("max_occurrences"),
            occurrenceCount = intOrNull("occurrence_count") ?: 0,
        )
    }

    private fun parseWeekdays(csv: String?): Set<Int> {
        if (csv.isNullOrEmpty()) return emptySet()
        return csv.split(",").mapNotNull { it.trim().toIntOrNull() }.toSet()
    }

    // ── Recurrence (mirror of ScheduledMessage.advanceAfterSend) ──────────────

    private fun advance(row: Row, sent: Boolean): ContentValues {
        if (!sent) {
            return ContentValues().apply { put("status", "failed") }
        }
        val newCount = row.occurrenceCount + 1
        val next = nextOccurrence(row)
        val exhausted = next == null ||
            (row.endType == "afterCount" && row.maxOccurrences != null &&
                newCount >= row.maxOccurrences) ||
            (row.endType == "onDate" && row.endDate != null && next > row.endDate)

        return ContentValues().apply {
            put("occurrence_count", newCount)
            if (exhausted) {
                put("status", "completed")
            } else {
                put("scheduled_at", next)
            }
        }
    }

    /** Next fire time (epoch millis) after [Row.scheduledAt], or null for one-shot. */
    private fun nextOccurrence(row: Row): Long? {
        val cal = Calendar.getInstance().apply { timeInMillis = row.scheduledAt }
        return when (row.repeat) {
            "daily" -> {
                cal.add(Calendar.DAY_OF_MONTH, row.repeatEvery)
                cal.timeInMillis
            }
            "weekly" -> {
                if (row.weekdays.isEmpty()) {
                    cal.add(Calendar.DAY_OF_MONTH, 7 * row.repeatEvery)
                    cal.timeInMillis
                } else {
                    // Walk forward to the next selected weekday.
                    for (i in 1..7) {
                        cal.add(Calendar.DAY_OF_MONTH, 1)
                        if (row.weekdays.contains(dartWeekday(cal))) return cal.timeInMillis
                    }
                    null
                }
            }
            "monthly" -> {
                // Calendar.add(MONTH) clamps to the last valid day automatically.
                cal.add(Calendar.MONTH, row.repeatEvery)
                cal.timeInMillis
            }
            else -> null
        }
    }

    /** Converts Calendar's DAY_OF_WEEK (Sun=1…Sat=7) to Dart's (Mon=1…Sun=7). */
    private fun dartWeekday(cal: Calendar): Int {
        val c = cal.get(Calendar.DAY_OF_WEEK)
        return if (c == Calendar.SUNDAY) 7 else c - 1
    }

    // ── Sending ────────────────────────────────────────────────────────────--

    private fun sendSms(context: Context, phone: String, body: String): Boolean {
        return try {
            @Suppress("DEPRECATION")
            val sm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                SmsManager.getDefault()
            }
            val parts = sm.divideMessage(body)
            if (parts.size == 1) {
                sm.sendTextMessage(phone, null, body, null, null)
            } else {
                sm.sendMultipartTextMessage(phone, null, parts, null, null)
            }
            Log.d(TAG, "Sent scheduled SMS to $phone (${parts.size} part(s))")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send scheduled SMS: ${e.message}", e)
            false
        }
    }
}
