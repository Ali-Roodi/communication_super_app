package com.example.communication_super_app.hidden

import android.content.Context
import android.provider.CallLog
import android.util.Log
import java.util.concurrent.Executors
import org.json.JSONObject

/**
 * Keeps calls with hidden numbers out of the system call log (matrix rows 11
 * and 35: «بدون ثبت در OS»).
 *
 * Telecom writes every carrier call into `CallLog.Calls` itself when the call
 * ends, and a default dialer cannot stop it. So the row is moved instead:
 * sealed into [SealedInbox] (Dart puts it in the hidden call history) and
 * then deleted from the provider. Sealing comes first — if the delete fails
 * the next sweep seals it again, and Dart drops the duplicate; the other
 * order could lose the call.
 *
 * Sweeps run:
 * - right after a call with a hidden number ends ([sweepAfterCall] — the row
 *   appears a moment after `onCallRemoved`, so it polls briefly);
 * - when the app comes to the foreground and before the call-log mirror
 *   reads the provider (incremental, [RECENT_MS] back);
 * - over the whole log when the hidden set changes (a contact just hidden
 *   takes their past calls along).
 */
object HiddenCallLog {
    private const val TAG = "HiddenCallLog"

    /** An incremental sweep looks this far back: a row is stamped with the call's *start*. */
    private const val RECENT_MS = 2L * 24 * 60 * 60 * 1000

    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "hidden-call-log").apply { isDaemon = true }
    }

    /** Sweeps on the worker thread. */
    fun sweepAsync(context: Context, full: Boolean) {
        val app = context.applicationContext
        if (!HiddenNumbers.any(app)) return
        worker.execute { sweep(app, full) }
    }

    /**
     * After a hidden call: telecom logs it asynchronously, so look a few
     * times over ~15 s and stop at the first sweep that moved something.
     */
    fun sweepAfterCall(context: Context) {
        val app = context.applicationContext
        worker.execute {
            for (delay in longArrayOf(700, 1_000, 1_500, 2_500, 4_000, 6_000)) {
                Thread.sleep(delay)
                if (sweep(app, full = false) > 0) return@execute
            }
        }
    }

    /** Moves every hidden row; returns how many. Runs on the caller's thread. */
    @Synchronized
    fun sweep(context: Context, full: Boolean): Int {
        if (!HiddenNumbers.any(context)) return 0
        val selection = if (full) null else "${CallLog.Calls.DATE} >= ?"
        val args = if (full) null else arrayOf((System.currentTimeMillis() - RECENT_MS).toString())
        val found = ArrayList<Pair<Long, JSONObject>>()
        try {
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(
                    CallLog.Calls._ID,
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.TYPE,
                    CallLog.Calls.DATE,
                    CallLog.Calls.DURATION,
                    CallLog.Calls.PHONE_ACCOUNT_ID,
                ),
                selection,
                args,
                null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val number = c.getString(1) ?: continue
                    if (!HiddenNumbers.isHidden(context, number)) continue
                    found.add(
                        c.getLong(0) to JSONObject().apply {
                            put("k", SealedInbox.KIND_CALL)
                            put("number", number)
                            put("type", c.getInt(2))
                            put("date", c.getLong(3))
                            put("duration", c.getLong(4))
                            put("account", c.getString(5) ?: JSONObject.NULL)
                        },
                    )
                }
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "No call-log access")
            return 0
        } catch (e: Exception) {
            Log.e(TAG, "Reading the call log failed: ${e.javaClass.simpleName}")
            return 0
        }
        var moved = 0
        for ((id, record) in found) {
            if (!SealedInbox.enqueue(context, SealedInbox.KIND_CALL, record)) continue
            try {
                context.contentResolver.delete(
                    CallLog.Calls.CONTENT_URI,
                    "${CallLog.Calls._ID} = ?",
                    arrayOf(id.toString()),
                )
                moved++
            } catch (e: Exception) {
                Log.w(TAG, "Deleting a hidden call-log row failed: ${e.javaClass.simpleName}")
            }
        }
        if (moved > 0) Log.d(TAG, "Moved $moved call(s) out of the call log")
        return moved
    }
}
