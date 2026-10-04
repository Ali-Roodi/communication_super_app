package com.example.communication_super_app.security

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * «کنترل امنیت سامانه» (row 29) and «عکس از ورود ناموفق» (row 32), as
 * methods of the secure section's native channel `…/hidden` (`HiddenHandler`
 * hands every name starting with `security.` here — the photos are sealed
 * to the same key as the hidden phonebook's records):
 *
 * - `security.deviceReport` → [DeviceSecurity.report]
 * - `security.intruderStatus` → `{enabled, camera}`; `setIntruderEnabled {enabled}`
 * - `security.wrongPin {failures}` — every wrong app PIN, with the count in a row
 * - `security.intruderReport` → `{events, lastAt}`; `clearIntruderReport`
 * - `security.intruderFiles` → `[{name, blob}]`; `deleteIntruderFiles {names}`
 */
class SecurityHandler(private val context: Context) {
    companion object {
        const val PREFIX = "security."
        private const val TAG = "SecurityHandler"
    }

    private val main = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method.removePrefix(PREFIX)) {
                "deviceReport" -> background(result) { DeviceSecurity.report(context) }
                "intruderStatus" -> result.success(
                    mapOf(
                        "enabled" to IntruderCamera.isEnabled(context),
                        "camera" to IntruderCamera.hasCamera(context),
                    ),
                )
                "setIntruderEnabled" -> {
                    IntruderCamera.setEnabled(context, call.argument<Boolean>("enabled") == true)
                    result.success(null)
                }
                "wrongPin" -> {
                    IntruderCamera.onWrongPin(context, call.argument<Int>("failures") ?: 0)
                    result.success(null)
                }
                "intruderReport" -> result.success(IntruderCamera.pendingReport(context))
                "clearIntruderReport" -> {
                    IntruderCamera.clearReport(context)
                    result.success(null)
                }
                "intruderFiles" -> background(result) {
                    IntruderCamera.files(context).map { (name, blob) ->
                        mapOf("name" to name, "blob" to blob)
                    }
                }
                "deleteIntruderFiles" -> {
                    IntruderCamera.delete(context, call.argument<List<String>>("names") ?: emptyList())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "${call.method} failed: ${e.javaClass.simpleName}")
                result.error("FAILED", e.javaClass.simpleName, null)
            }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        thread(name = "security-channel") {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                Log.e(TAG, "Security call failed: ${e.javaClass.simpleName}")
                main.post { result.error("FAILED", e.javaClass.simpleName, null) }
            }
        }
    }
}
