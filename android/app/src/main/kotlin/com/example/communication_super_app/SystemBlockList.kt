package com.example.communication_super_app

import android.content.ContentValues
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.BlockedNumberContract
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Android's own blocked list (`BlockedNumberContract`) — the one telecom, the
 * SMS framework, the phone's own dialer and messages app and every other app
 * that asks consult. A number this app blocks is written here as well as into
 * its own `blocked_numbers` table, so it is blocked phone-wide; one blocked
 * in another app shows up in «هرزنامه و مسدودشده» (`BlockedNumbersRepository
 * .syncWithSystem` reconciles the two).
 *
 * Only the default dialer or SMS app (or the carrier) may read or write the
 * list. [available] says whether this app may right now; without either role
 * every call answers "nothing" rather than throwing, and blocking stays
 * app-only until a role is held again.
 */
object SystemBlockList {
    private const val TAG = "SystemBlockList"
    const val CHANNEL = "com.example.communication_super_app/blocked"

    fun available(context: Context): Boolean = try {
        BlockedNumberContract.canCurrentUserBlockNumbers(context)
    } catch (e: Exception) {
        false
    }

    /** Every number on the list, as it was entered (its E.164 form when it has none). */
    fun list(context: Context): List<String> {
        if (!available(context)) return emptyList()
        val out = ArrayList<String>()
        try {
            context.contentResolver.query(
                BlockedNumberContract.BlockedNumbers.CONTENT_URI,
                arrayOf(
                    BlockedNumberContract.BlockedNumbers.COLUMN_ORIGINAL_NUMBER,
                    BlockedNumberContract.BlockedNumbers.COLUMN_E164_NUMBER,
                ),
                null,
                null,
                null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val number = c.getString(0)?.takeIf { it.isNotBlank() }
                        ?: c.getString(1)?.takeIf { it.isNotBlank() }
                        ?: continue
                    out.add(number)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Reading the blocked list failed: ${e.javaClass.simpleName}")
        }
        return out
    }

    /**
     * Adds every number not already on the list, and answers the ones that
     * are on it afterwards — so the caller records only what actually got
     * there (a write the provider refused is tried again on the next sync).
     */
    fun add(context: Context, numbers: List<String>): List<String> {
        if (!available(context)) return emptyList()
        val blocked = ArrayList<String>()
        for (number in numbers) {
            if (number.isBlank()) continue
            try {
                if (!BlockedNumberContract.isBlocked(context, number)) {
                    context.contentResolver.insert(
                        BlockedNumberContract.BlockedNumbers.CONTENT_URI,
                        ContentValues().apply {
                            put(BlockedNumberContract.BlockedNumbers.COLUMN_ORIGINAL_NUMBER, number)
                        },
                    )
                }
                if (BlockedNumberContract.isBlocked(context, number)) blocked.add(number)
            } catch (e: Exception) {
                Log.w(TAG, "Blocking a number failed: ${e.javaClass.simpleName}")
            }
        }
        return blocked
    }

    /**
     * Takes every number off the list — in whatever format it was entered:
     * `unblock` matches the original and the E.164 form. How many rows went,
     * or -1 when the list may not be written at all — the app then keeps the
     * removal pending (`BlockedNumbersRepository.syncWithSystem`).
     */
    fun remove(context: Context, numbers: List<String>): Int {
        if (!available(context)) return -1
        var removed = 0
        for (number in numbers) {
            if (number.isBlank()) continue
            try {
                removed += BlockedNumberContract.unblock(context, number)
            } catch (e: Exception) {
                Log.w(TAG, "Unblocking a number failed: ${e.javaClass.simpleName}")
            }
        }
        return removed
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** `available` / `list` / `add {numbers}` / `remove {numbers}` — off the main thread. */
    fun setup(context: Context, channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            val numbers = call.argument<List<String>>("numbers").orEmpty()
            io.execute {
                val answer: Any? = try {
                    when (call.method) {
                        "available" -> available(context)
                        "list" -> list(context)
                        "add" -> add(context, numbers)
                        "remove" -> remove(context, numbers)
                        else -> {
                            main.post { result.notImplemented() }
                            return@execute
                        }
                    }
                } catch (e: Exception) {
                    main.post { result.error("BLOCKED_LIST", e.javaClass.simpleName, null) }
                    return@execute
                }
                main.post { result.success(answer) }
            }
        }
    }
}
