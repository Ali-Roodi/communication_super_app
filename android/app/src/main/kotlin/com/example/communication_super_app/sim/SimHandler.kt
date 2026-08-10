package com.example.communication_super_app.sim

import android.content.Context
import android.os.Build
import android.telephony.SubscriptionManager
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Publishes the SIM roster to Flutter and keeps it live.
 *
 * The list is pushed, not polled: a SIM inserted, removed or renamed while the
 * app is running has to change the composer's SIM chip and the dialer's SIM
 * button immediately — and *this* is also what re-reads the SIM address book,
 * which is why inserting a second SIM used to show none of its contacts until
 * the next cold start.
 */
class SimHandler(private val context: Context) {

    companion object {
        const val METHOD_CHANNEL = "com.example.communication_super_app/sim"
        const val EVENT_CHANNEL = "com.example.communication_super_app/sim_events"
        private const val TAG = "SimHandler"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var subscriptionsListener: SubscriptionManager.OnSubscriptionsChangedListener? = null

    fun setupMethodChannel(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getSubscriptions" -> result.success(
                        // withNumbers: the picker shows each card's own number.
                        SimRegistry.subscriptions(context, withNumbers = true)
                            .map { it.toMap() }
                    )
                    // Call-log rows record a PhoneAccount *id string*, not a
                    // subscription id, and no public API maps the two. This
                    // hands Dart the whole (tiny) mapping once so the call
                    // history can name the SIM of every row without a channel
                    // call per row.
                    "getPhoneAccounts" -> result.success(
                        SimRegistry.callCapableAccounts(context).map { (handle, _) ->
                            mapOf(
                                "accountId" to handle.id,
                                "subscriptionId" to
                                    SimRegistry.subscriptionIdForAccountId(context, handle.id),
                            )
                        }
                    )
                    "getDefaults" -> result.success(
                        mapOf(
                            "sms" to SimRegistry.defaultSmsSubscriptionId(),
                            "voice" to SimRegistry.defaultVoiceSubscriptionId(),
                            "data" to SimRegistry.defaultDataSubscriptionId(),
                        )
                    )
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.error("PERMISSION_DENIED", e.message, null)
            } catch (e: Exception) {
                result.error("SIM_ERROR", e.message, null)
            }
        }
    }

    fun setupEventChannel(channel: EventChannel) {
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                // Replay the current roster immediately: a listener attaching
                // after a SIM change would otherwise wait for the *next* one.
                emit()
                registerListener()
            }

            override fun onCancel(arguments: Any?) {
                unregisterListener()
                eventSink = null
            }
        })
    }

    private fun registerListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) return
        if (subscriptionsListener != null) return
        try {
            val manager = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as? SubscriptionManager ?: return
            val listener = object : SubscriptionManager.OnSubscriptionsChangedListener() {
                override fun onSubscriptionsChanged() {
                    // The roster really changed — drop the native cache before
                    // anyone reads a stale one (a notification arriving in the
                    // same second as a SIM swap would otherwise label it wrong).
                    SimRegistry.invalidate()
                    emit()
                }
            }
            subscriptionsListener = listener
            manager.addOnSubscriptionsChangedListener(listener)
        } catch (e: SecurityException) {
            // READ_PHONE_STATE not granted yet. The roster is still readable
            // once it is — PermissionGate re-asks and Dart re-fetches then.
            Log.w(TAG, "subscription listener denied: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "subscription listener failed: ${e.message}", e)
        }
    }

    private fun unregisterListener() {
        val listener = subscriptionsListener ?: return
        subscriptionsListener = null
        try {
            val manager = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as? SubscriptionManager
            manager?.removeOnSubscriptionsChangedListener(listener)
        } catch (e: Exception) {
            Log.e(TAG, "remove subscription listener failed: ${e.message}")
        }
    }

    private fun emit() {
        val payload =
            SimRegistry.subscriptions(context, withNumbers = true).map { it.toMap() }
        // OnSubscriptionsChangedListener fires on the main looper already, but
        // the initial replay can come from the platform channel thread.
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try {
                eventSink?.success(payload)
            } catch (e: Exception) {
                Log.e(TAG, "emit failed: ${e.message}")
            }
        }
    }

    fun dispose() {
        unregisterListener()
        eventSink = null
    }
}
