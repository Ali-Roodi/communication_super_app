package com.example.communication_super_app.hidden

import android.app.NotificationManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * The hidden phonebook's native half, over `…/hidden`. Dart owns the
 * phonebook (in `secure.db`) and tells Kotlin what it needs to act while the
 * section is locked:
 *
 * - `setNumbers {numbers}` → Boolean changed — the hidden set, as tags; a
 *   change sweeps the whole call log
 * - `setNames {names: {number: name}}` / `clearNames` — memory only, while open
 * - `setSealingKey {public}` — the section's public key for [SealedInbox]
 * - `sweep {full}` → Int moved
 * - `isHidden {number}` → Boolean
 * - `forget` — the section was deleted
 * - `clearMissedNotice` — the hidden call history is on screen
 *
 * Nothing here is ever logged with a number or a name.
 */
class HiddenHandler(private val context: Context) {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/hidden"
        private const val TAG = "HiddenHandler"

        /** Set on the launch intent of the hidden missed-call card. */
        const val EXTRA_OPEN_HIDDEN_CALLS = "open_hidden_calls"

        /** The hidden missed-call card: a bare id, like «پیام رمز جدید». */
        const val MISSED_NOTICE_ID = 0x5EC1

        /** How many hidden calls the card stands for; reset when it is cleared. */
        val hiddenMissed = java.util.concurrent.atomic.AtomicInteger(0)

        fun cancelMissedNotice(context: Context) {
            hiddenMissed.set(0)
            try {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(MISSED_NOTICE_ID)
            } catch (e: Exception) {
                // Nothing to cancel.
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "setNumbers" -> {
                        val numbers = call.argument<List<String>>("numbers") ?: emptyList()
                        background(result) {
                            val changed = HiddenNumbers.setNumbers(context, numbers)
                            if (changed) HiddenCallLog.sweep(context, full = true)
                            changed
                        }
                    }
                    "setNames" -> {
                        HiddenNumbers.setNames(call.argument<Map<String, String>>("names") ?: emptyMap())
                        result.success(null)
                    }
                    "clearNames" -> {
                        HiddenNumbers.clearNames()
                        result.success(null)
                    }
                    "setSealingKey" -> {
                        val public = call.argument<ByteArray>("public")
                            ?: return@setMethodCallHandler result.error("BAD_ARGS", "public", null)
                        HiddenNumbers.setSealingKey(context, public)
                        result.success(null)
                    }
                    "sweep" -> {
                        val full = call.argument<Boolean>("full") ?: false
                        background(result) { HiddenCallLog.sweep(context, full) }
                    }
                    "isHidden" -> {
                        val number = call.argument<String>("number")
                        background(result) { HiddenNumbers.isHidden(context, number) }
                    }
                    "forget" -> {
                        HiddenNumbers.forget(context)
                        result.success(null)
                    }
                    "clearMissedNotice" -> {
                        cancelMissedNotice(context)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "${call.method} failed: ${e.javaClass.simpleName}")
                result.error("FAILED", e.javaClass.simpleName, null)
            }
        }
    }

    /** Keystore and provider work stays off the main thread. */
    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        thread(name = "hidden-channel") {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                Log.e(TAG, "Hidden call failed: ${e.javaClass.simpleName}")
                main.post { result.error("FAILED", e.javaClass.simpleName, null) }
            }
        }
    }
}
