package com.example.communication_super_app.scheduled

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge that lets the alarm receiver hand delivery **back to Dart** whenever the
 * Flutter engine is alive.
 *
 * Why: `ScheduledSmsWorker` can send an SMS from a dead process, but it writes
 * straight to SQLite. If it does that while the app is running, the in-memory
 * `ScheduledMessageBloc` / `MessageBloc` never learn about it — the chat keeps
 * showing the scheduled ghost bubble and never renders the sent message. So when
 * the engine is attached we ask Dart to run the delivery instead; the native
 * worker is the cold-start fallback.
 *
 * [channel] is set by `MainActivity.configureFlutterEngine` and cleared in
 * `onDestroy`, mirroring `SmsHandler.isDynamicReceiverActive`.
 */
object ScheduledSmsChannel {
    private const val TAG = "ScheduledSmsChannel"

    /** Dart-facing method invoked to run a delivery sweep in the Flutter isolate. */
    private const val METHOD_DELIVER_DUE = "deliverDue"

    @JvmStatic
    @Volatile
    var channel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Asks the Flutter side to deliver every due schedule.
     *
     * Returns false immediately when no engine is attached, so the caller can
     * fall back to [ScheduledSmsWorker.processDue]. When Dart is reached but the
     * call fails, [onFallback] runs instead — a dropped delivery would otherwise
     * wait for the next alarm.
     */
    fun requestDartDelivery(onFallback: () -> Unit): Boolean {
        val target = channel ?: return false
        mainHandler.post {
            // Re-read: the activity may have been destroyed between the check and
            // this post, which would make invokeMethod throw.
            val live = channel
            if (live == null) {
                onFallback()
                return@post
            }
            live.invokeMethod(
                METHOD_DELIVER_DUE,
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        Log.d(TAG, "Dart handled the scheduled delivery")
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.w(TAG, "Dart delivery failed ($code); falling back to native")
                        onFallback()
                    }

                    override fun notImplemented() {
                        Log.w(TAG, "Dart has no deliverDue handler; falling back to native")
                        onFallback()
                    }
                },
            )
        }
        return true
    }
}
