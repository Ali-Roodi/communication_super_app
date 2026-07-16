package com.example.communication_super_app

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log

/**
 * Native-side lookup into the app's `blocked_numbers` sqflite table, for code
 * paths that run without the Flutter engine (cold-start SMS receivers, the
 * in-call service). Mirrors `BlockedNumbersRepository.isBlocked` — the
 * `normalized` column holds the national `09xxxxxxxxx` form produced by
 * `PhoneNormalizer.toThreadId`.
 */
object BlockedNumbers {
    private const val TAG = "BlockedNumbers"
    private const val DB_NAME = "communication_app.db"

    fun isBlocked(context: Context, phone: String): Boolean {
        val normalized = normalizeToThreadId(phone)
        if (normalized.isEmpty()) return false
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists()) return false
        return try {
            SQLiteDatabase.openDatabase(
                dbFile.path, null, SQLiteDatabase.OPEN_READONLY,
            ).use { db ->
                db.rawQuery(
                    "SELECT 1 FROM blocked_numbers WHERE normalized = ? LIMIT 1",
                    arrayOf(normalized),
                ).use { c -> c.moveToFirst() }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Blocked lookup failed: ${e.message}")
            false
        }
    }

    /** Mirrors PhoneNormalizer.toThreadId (national 09xxxxxxxxx form). */
    fun normalizeToThreadId(phone: String): String {
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
