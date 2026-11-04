package com.example.communication_super_app.reminders

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Channel behind `lib/features/call_history/services/call_reminders.dart`.
 *
 * - `list` → the pending reminders, soonest first; also re-arms the alarm
 * - `add {number, kind, at, name}` → the new reminder
 * - `remove {id}`
 * - `alertsEnabled` → Boolean
 *
 * Sends `changed` when the list changed natively (one fired, or was snoozed).
 */
class CallReminderHandler(private val context: Context) {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/call_reminders"
        private const val TAG = "CallReminderHandler"
    }

    private val main = Handler(Looper.getMainLooper())

    fun setup(channel: MethodChannel) {
        CallReminders.onChanged = { main.post { channel.invokeMethod("changed", null) } }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> background(result) {
                    CallReminders.rearm(context)
                    CallReminders.list(context).map { it.toMap() }
                }
                "add" -> {
                    val number = call.argument<String>("number").orEmpty()
                    val kind = call.argument<String>("kind") ?: CallReminders.KIND_CALL
                    val at = call.argument<Number>("at")?.toLong()
                    val name = call.argument<String>("name")
                    if (number.isEmpty() || at == null) {
                        result.error("BAD_ARGS", "number and at are required", null)
                    } else {
                        background(result) {
                            CallReminders.add(context, number, kind, at, name).toMap()
                        }
                    }
                }
                "remove" -> {
                    val id = call.argument<String>("id").orEmpty()
                    background(result) {
                        CallReminders.remove(context, id)
                        null
                    }
                }
                "alertsEnabled" -> background(result) { CallReminders.alertsEnabled(context) }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        CallReminders.onChanged = null
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        thread(name = "call-reminders") {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                Log.e(TAG, "call failed: ${e.javaClass.simpleName}")
                main.post { result.error("FAILED", e.javaClass.simpleName, null) }
            }
        }
    }
}
