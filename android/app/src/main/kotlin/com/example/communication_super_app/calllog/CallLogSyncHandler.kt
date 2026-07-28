package com.example.communication_super_app.calllog

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the device call-log provider to Flutter for two-way sync:
 *
 * - **EventChannel** (`call_log_events`): registers a [ContentObserver] on
 *   `CallLog.Calls.CONTENT_URI` and pushes a debounced "changed" event to Dart
 *   whenever the system writes a new call (or anything else mutates the log).
 *   Dart reacts by running a mirror-sync, so a call shows up in «اخیر»
 *   moments after it ends — no manual refresh.
 *
 * - **MethodChannel** (`call_log`): `deleteCallLogs(ids)` deletes rows from the
 *   device provider (requires WRITE_CALL_LOG, already declared + granted with
 *   the Phone permission group). This is what makes an in-app delete *global*
 *   instead of resurrecting on the next device import.
 */
class CallLogSyncHandler(private val context: Context) {
    companion object {
        private const val TAG = "CallLogSyncHandler"

        /** A single call typically triggers several onChange callbacks in a
         *  burst; debounce them into one Dart-side sync. */
        private const val DEBOUNCE_MS = 500L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var observer: ContentObserver? = null

    private val notifyRunnable = Runnable {
        try {
            eventSink?.success(mapOf("changed" to true))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to notify Flutter of call-log change: ${e.message}")
        }
    }

    fun setupMethodChannel(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "deleteCallLogs" -> {
                    val ids = call.argument<List<String>>("ids")
                    if (ids.isNullOrEmpty()) {
                        result.success(0)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(deleteFromProvider(ids))
                    } catch (e: SecurityException) {
                        result.error("PERMISSION_DENIED", "WRITE_CALL_LOG not granted", null)
                    } catch (e: Exception) {
                        result.error("DELETE_FAILED", e.message, null)
                    }
                }
                // Ids only — the deletion half of the mirror-sync needs to know
                // *which* rows still exist, not what is in them. Reading full
                // rows for that (thousands of maps over the channel) is what
                // made every resume stall on a long call history.
                "callLogIdsSince" -> {
                    val sinceMs = when (val v = call.argument<Any>("sinceMs")) {
                        is Int -> v.toLong()
                        is Long -> v
                        else -> 0L
                    }
                    try {
                        result.success(queryIdsSince(sinceMs))
                    } catch (e: SecurityException) {
                        result.error("PERMISSION_DENIED", "READ_CALL_LOG not granted", null)
                    } catch (e: Exception) {
                        result.error("QUERY_FAILED", e.message, null)
                    }
                }
                // Registration can fail at app start if READ_CALL_LOG hasn't
                // been granted yet; Dart calls this again after the permission
                // gate so the observer always ends up attached.
                "ensureObserving" -> {
                    result.success(registerObserver())
                }
                else -> result.notImplemented()
            }
        }
    }

    fun setupEventChannel(channel: EventChannel) {
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                registerObserver()
            }

            override fun onCancel(arguments: Any?) {
                unregisterObserver()
                eventSink = null
            }
        })
    }

    /**
     * Provider row ids of every call at or after [sinceMs], newest first.
     * Projection is `_ID` alone, so the payload stays a list of short strings
     * even on a phone with tens of thousands of calls.
     */
    private fun queryIdsSince(sinceMs: Long): List<String> {
        val ids = ArrayList<String>()
        context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls._ID),
            if (sinceMs > 0) "${CallLog.Calls.DATE} >= ?" else null,
            if (sinceMs > 0) arrayOf(sinceMs.toString()) else null,
            "${CallLog.Calls.DATE} DESC"
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(CallLog.Calls._ID)
            if (idIndex < 0) return ids
            while (cursor.moveToNext()) {
                ids.add(cursor.getString(idIndex) ?: continue)
            }
        }
        return ids
    }

    /** Deletes the given provider `_id`s. Returns the number of rows removed. */
    private fun deleteFromProvider(ids: List<String>): Int {
        // Only numeric ids can be provider rows; anything else (Dart-side UUID
        // fallbacks) has no device counterpart.
        val numeric = ids.filter { it.isNotEmpty() && it.all(Char::isDigit) }
        if (numeric.isEmpty()) return 0
        val placeholders = numeric.joinToString(",") { "?" }
        return context.contentResolver.delete(
            CallLog.Calls.CONTENT_URI,
            "${CallLog.Calls._ID} IN ($placeholders)",
            numeric.toTypedArray()
        )
    }

    /** Idempotent. Returns true when the observer is attached. */
    private fun registerObserver(): Boolean {
        if (observer != null) return true
        val obs = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean) {
                mainHandler.removeCallbacks(notifyRunnable)
                mainHandler.postDelayed(notifyRunnable, DEBOUNCE_MS)
            }
        }
        return try {
            context.contentResolver.registerContentObserver(
                CallLog.Calls.CONTENT_URI, /* notifyForDescendants = */ true, obs
            )
            observer = obs
            Log.d(TAG, "Call-log ContentObserver registered")
            true
        } catch (e: SecurityException) {
            // READ_CALL_LOG not granted yet — Dart retries via ensureObserving.
            Log.w(TAG, "Cannot observe call log yet: ${e.message}")
            false
        }
    }

    private fun unregisterObserver() {
        observer?.let {
            try {
                context.contentResolver.unregisterContentObserver(it)
            } catch (_: Exception) {
            }
        }
        observer = null
        mainHandler.removeCallbacks(notifyRunnable)
    }

    fun dispose() {
        unregisterObserver()
        eventSink = null
    }
}
