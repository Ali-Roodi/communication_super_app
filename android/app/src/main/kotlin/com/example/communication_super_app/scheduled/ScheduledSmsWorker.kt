package com.example.communication_super_app.scheduled

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.telephony.SmsManager
import android.util.Log
import java.util.Calendar
import java.util.UUID

/**
 * Headless delivery of due scheduled messages (PHASE 2).
 *
 * Runs from an AlarmManager broadcast even when the Flutter engine is not
 * alive. It opens the same `sqflite` database directly, **claims** every pending
 * message whose time has arrived, sends it with [SmsManager], records the sent
 * message in the `messages` table, and advances the row (recurrence) or
 * completes it.
 *
 * ## Claiming
 * The Dart deliverer (`ScheduledDeliveryService`) may be running at the same
 * instant. Both stamp a random token onto the due rows in a single atomic
 * UPDATE and then only process rows carrying their own token, so a message is
 * never sent twice. A row left in `sending` (process killed mid-send) is
 * released back to `pending` after [STALE_CLAIM_MS].
 *
 * IMPORTANT: the table/column names, the enum string values, the retry policy
 * and the recurrence logic here MUST stay in sync with the Dart side
 * (`AppConstants.scheduledMessagesTable`, `ScheduledMessage`,
 * `scheduled_message_model.dart`). Keep the two in lock-step when either
 * changes.
 */
object ScheduledSmsWorker {
    private const val TAG = "ScheduledSmsWorker"
    private const val DB_NAME = "communication_app.db"
    private const val TABLE = "scheduled_messages"
    private const val MESSAGES_TABLE = "messages"

    /** Mirror of `ScheduledMessage.staleClaimTimeout`. */
    private const val STALE_CLAIM_MS = 2 * 60 * 1000L

    /** Mirror of `ScheduledMessage.maxAttempts`. */
    private const val MAX_ATTEMPTS = 3

    /** Bounds the catch-up walk; mirror of `_maxSkipAhead`. */
    private const val MAX_SKIP_AHEAD = 5000

    /** Mirror of `ScheduledMessage.retryDelay`. */
    private fun retryDelayMs(attempt: Int): Long =
        if (attempt <= 1) 60_000L else 5 * 60_000L

    /** Sends every due message and updates its row. Safe to call repeatedly. */
    fun processDue(context: Context) {
        val db = openDb(context, readOnly = false) ?: return
        try {
            val now = System.currentTimeMillis()
            val token = UUID.randomUUID().toString()
            releaseStaleClaims(db, now)
            val due = claimDue(db, now, token)
            Log.d(TAG, "Claimed ${due.size} due scheduled message(s)")
            for (row in due) {
                val sent = sendSms(context, row.phoneNumber, row.body)
                if (sent) {
                    persistSentMessage(db, row.phoneNumber, row.body, now)
                    db.update(TABLE, advance(row, now), "id = ?", arrayOf(row.id))
                } else {
                    db.update(TABLE, failAttempt(row, now), "id = ?", arrayOf(row.id))
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "processDue failed: ${e.message}", e)
        } finally {
            db.close()
        }
    }

    /** The soonest pending message's due time and its jitter window. */
    data class Earliest(val at: Long, val jitterMinutes: Int)

    /**
     * The soonest instant at which a pending message becomes due (its nominal
     * time, or its retry time when a previous attempt failed), plus that
     * message's jitter window. Null when nothing is pending.
     */
    fun earliestPending(context: Context): Earliest? {
        val db = openDb(context, readOnly = true) ?: return null
        return try {
            db.rawQuery(
                "SELECT MAX(scheduled_at, COALESCE(next_attempt_at, 0)) AS due_at, jitter " +
                    "FROM $TABLE WHERE status = 'pending' ORDER BY due_at ASC LIMIT 1",
                null,
            ).use { c ->
                if (c.moveToFirst()) Earliest(c.getLong(0), jitterMinutes(c.getString(1))) else null
            }
        } catch (e: Exception) {
            Log.e(TAG, "earliestPending failed: ${e.message}")
            null
        } finally {
            db.close()
        }
    }

    /**
     * Opens the sqflite database with WAL + a busy timeout, so a concurrent
     * write from the Dart side blocks briefly instead of throwing
     * SQLiteDatabaseLockedException (which used to silently drop the whole
     * delivery batch).
     */
    private fun openDb(context: Context, readOnly: Boolean): SQLiteDatabase? {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) return null // DB is created on first app launch
        return try {
            val flags = if (readOnly) {
                SQLiteDatabase.OPEN_READONLY
            } else {
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING
            }
            SQLiteDatabase.openDatabase(dbFile.path, null, flags).apply {
                if (!readOnly) rawQuery("PRAGMA busy_timeout = 5000", null).use { it.moveToFirst() }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open DB: ${e.message}")
            null
        }
    }

    /** Maps the stored jitter enum value to its window length in minutes. */
    private fun jitterMinutes(value: String?): Int = when (value) {
        "min10" -> 10
        "min30" -> 30
        "min60" -> 60
        else -> 0
    }

    // ── Claim ─────────────────────────────────────────────────────────────────

    /** Frees rows whose owner died mid-send. Mirror of `releaseStaleClaims`. */
    private fun releaseStaleClaims(db: SQLiteDatabase, now: Long) {
        db.execSQL(
            "UPDATE $TABLE SET status = 'pending', claim_token = NULL, claimed_at = NULL " +
                "WHERE status = 'sending' AND (claimed_at IS NULL OR claimed_at <= ?)",
            arrayOf<Any>(now - STALE_CLAIM_MS),
        )
    }

    /**
     * Atomically marks the due rows `sending` with [token], then reads back
     * exactly the rows this caller owns. A competing deliverer's UPDATE matches
     * zero rows and it walks away empty-handed.
     */
    private fun claimDue(db: SQLiteDatabase, now: Long, token: String): List<Row> {
        val values = ContentValues().apply {
            put("status", "sending")
            put("claim_token", token)
            put("claimed_at", now)
        }
        val claimed = db.update(
            TABLE,
            values,
            "status = 'pending' AND scheduled_at <= ? " +
                "AND (next_attempt_at IS NULL OR next_attempt_at <= ?)",
            arrayOf(now.toString(), now.toString()),
        )
        if (claimed == 0) return emptyList()

        val out = mutableListOf<Row>()
        db.query(
            TABLE,
            null,
            "claim_token = ? AND status = 'sending'",
            arrayOf(token),
            null,
            null,
            "scheduled_at ASC",
        ).use { c ->
            while (c.moveToNext()) out.add(readRow(c))
        }
        return out
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
        val attemptCount: Int,
    )

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
            attemptCount = intOrNull("attempt_count") ?: 0,
        )
    }

    private fun parseWeekdays(csv: String?): Set<Int> {
        if (csv.isNullOrEmpty()) return emptySet()
        return csv.split(",").mapNotNull { it.trim().toIntOrNull() }.toSet()
    }

    // ── Row transitions (mirror of ScheduledMessage) ──────────────────────────

    /** Mirror of `ScheduledMessage.advanceAfterSend`. Always releases the claim. */
    private fun advance(row: Row, now: Long): ContentValues {
        val newCount = row.occurrenceCount + 1
        var next = nextOccurrence(row, row.scheduledAt)
        // Skip occurrences already in the past instead of replaying them.
        var guard = 0
        while (next != null && next <= now && guard++ < MAX_SKIP_AHEAD) {
            val after = nextOccurrence(row, next)
            if (after == null || after == next) break
            next = after
        }

        val nextAt: Long? = next
        val exhausted = nextAt == null ||
            (row.endType == "afterCount" && row.maxOccurrences != null &&
                newCount >= row.maxOccurrences) ||
            (row.endType == "onDate" && row.endDate != null && nextAt > row.endDate)

        return ContentValues().apply {
            put("occurrence_count", newCount)
            put("attempt_count", 0)
            putNull("next_attempt_at")
            putNull("last_error")
            putNull("claim_token")
            putNull("claimed_at")
            if (exhausted || nextAt == null) {
                put("status", "completed")
            } else {
                put("status", "pending")
                put("scheduled_at", nextAt)
            }
        }
    }

    /** Mirror of `ScheduledMessage.withFailedAttempt`. Always releases the claim. */
    private fun failAttempt(row: Row, now: Long): ContentValues {
        val attempts = row.attemptCount + 1
        return ContentValues().apply {
            put("attempt_count", attempts)
            put("last_error", "SMS_SEND_FAILED")
            putNull("claim_token")
            putNull("claimed_at")
            if (attempts >= MAX_ATTEMPTS) {
                put("status", "failed")
                putNull("next_attempt_at")
            } else {
                put("status", "pending")
                put("next_attempt_at", now + retryDelayMs(attempts))
            }
        }
    }

    /** Next fire time (epoch millis) after [from], or null for one-shot. */
    private fun nextOccurrence(row: Row, from: Long): Long? {
        val cal = Calendar.getInstance().apply { timeInMillis = from }
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

    /**
     * Records the delivered message in the chat, mirroring
     * `MessageRepository.createMessage` for a sent message. Without this a
     * background-delivered scheduled SMS never appears in its conversation.
     */
    private fun persistSentMessage(
        db: SQLiteDatabase,
        phone: String,
        body: String,
        timestamp: Long,
    ) {
        try {
            val values = ContentValues().apply {
                put("id", UUID.randomUUID().toString())
                put("thread_id", normalizeToThreadId(phone))
                putNull("contact_id")
                put("phone_number", phone)
                put("body", body)
                put("type", "sent")
                put("status", "sent")
                put("timestamp", timestamp)
                put("is_read", 1)
            }
            // OR IGNORE: the unique (phone_number, body, timestamp, type) index
            // dedups against a later device-inbox import.
            db.insertWithOnConflict(
                MESSAGES_TABLE, null, values, SQLiteDatabase.CONFLICT_IGNORE,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist sent scheduled message: ${e.message}")
        }
    }

    /** Mirrors PhoneNormalizer.toThreadId (national 09xxxxxxxxx form). */
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
