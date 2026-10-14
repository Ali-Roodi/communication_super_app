package com.example.communication_super_app.security

import android.app.Activity
import android.content.Context
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Channel `…/app_lock` — what the app lock needs from the platform, in every
 * edition:
 *
 * - `biometricStatus` → see [BiometricGate.status]
 * - `authenticate {title, subtitle, negative}` → see [BiometricGate.authenticate]
 * - `createSentinel` → bool, `sentinelState` → string, `deleteSentinel`
 * - `setHideNotificationContent {value}` → [NotificationPrivacy]
 */
class AppLockHandler(
    private val context: Context,
    private val activity: () -> Activity?,
) {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/app_lock"
        private const val TAG = "AppLockHandler"
    }

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "biometricStatus" -> result.success(BiometricGate.status(context))
                "authenticate" -> {
                    val host = activity()
                    if (host == null || host.isFinishing || host.isDestroyed) {
                        result.success("unavailable")
                        return
                    }
                    BiometricGate.authenticate(
                        host,
                        title = call.argument<String>("title") ?: "",
                        subtitle = call.argument<String>("subtitle") ?: "",
                        negative = call.argument<String>("negative") ?: "",
                    ) { outcome -> result.success(outcome) }
                }
                // The lock screen went away under the prompt (the PIN was
                // typed meanwhile): the prompt goes with it.
                "cancelAuthentication" -> {
                    BiometricGate.cancel()
                    result.success(null)
                }
                "createSentinel" -> result.success(BiometricGate.createSentinel())
                "sentinelState" -> result.success(BiometricGate.sentinelState())
                "deleteSentinel" -> {
                    BiometricGate.deleteSentinel()
                    result.success(null)
                }
                "setHideNotificationContent" -> {
                    NotificationPrivacy.setHideContent(
                        context,
                        call.argument<Boolean>("value") ?: true,
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "${call.method} failed: ${e.javaClass.simpleName}")
            result.error("FAILED", e.javaClass.simpleName, null)
        }
    }

    /** The activity is going away: no prompt may outlive it. */
    fun dispose() = BiometricGate.cancel()
}
