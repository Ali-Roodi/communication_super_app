package com.example.communication_super_app.call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.DisconnectCause
import android.telecom.InCallService
import android.telecom.VideoProfile
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.communication_super_app.BlockedNumbers

/**
 * The in-call UI binding for cellular calls — bound by telecom while this app
 * holds the **default-dialer role** (ROLE_DIALER). Once bound, this app is the
 * ONLY call UI on the device: telecom stops showing the system dialer, so
 * every state below must reach Flutter or the user has no way to interact
 * with the call.
 *
 * Flow:
 * - Telecom binds and calls [onCallAdded]. A [Call.Callback] mirrors every
 *   state change into [CallEventStreamHandler] → Dart `DialerBloc` →
 *   IncomingCallScreen / InCallScreen.
 * - For an incoming call a **full-screen notification** is posted; if the app
 *   process is dead the fullScreenIntent cold-starts MainActivity and the
 *   sticky-state replay in [CallEventStreamHandler.onListen] re-delivers the
 *   INCOMING event once Flutter attaches.
 * - `CallHandler` drives actions (answer/reject/hangup/hold/DTMF) through
 *   [currentCall], and audio (mute/speaker) through [instance].
 *
 * NEVER request ROLE_DIALER unless this service is declared and functional —
 * incoming calls would have no UI at all.
 */
class CallInCallService : InCallService() {
    companion object {
        private const val TAG = "CallInCallService"
        private const val CHANNEL_ID = "incoming_call_channel"
        private const val MISSED_CHANNEL_ID = "missed_call_channel"
        private const val NOTIF_ID = 7001

        /** The bound service instance — audio routing entry point. */
        @JvmStatic
        @Volatile
        var instance: CallInCallService? = null

        /** The telecom Call currently in the foreground (most recent). */
        @JvmStatic
        @Volatile
        var currentCall: Call? = null

        /** Every telecom call currently bound (conference children included). */
        @JvmStatic
        val calls = java.util.concurrent.CopyOnWriteArrayList<Call>()

        /** Calls that are not children of a conference — what the UI counts. */
        @JvmStatic
        fun topLevelCalls(): List<Call> = calls.filter { it.parent == null }

        /** True when an active+held pair (or a telecom merge capability) exists. */
        @JvmStatic
        fun canMerge(): Boolean {
            val top = topLevelCalls()
            val hasPair = top.any { it.state == Call.STATE_ACTIVE } &&
                top.any { it.state == Call.STATE_HOLDING }
            val capMerge = top.any {
                it.details?.can(Call.Details.CAPABILITY_MERGE_CONFERENCE) == true
            }
            return top.size >= 2 && (hasPair || capMerge)
        }

        /** Last event pushed — replayed when the Flutter EventChannel attaches
         *  after a cold start (see CallEventStreamHandler.onListen). */
        @JvmStatic
        @Volatile
        var stickyState: Map<String, Any?>? = null

        private fun phoneOf(call: Call): String =
            call.details?.handle?.schemeSpecificPart ?: ""

        private fun directionOf(call: Call): String {
            val dir = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                call.details?.callDirection
            } else null
            return when (dir) {
                Call.Details.DIRECTION_INCOMING -> "incoming"
                Call.Details.DIRECTION_OUTGOING -> "outgoing"
                // Pre-Q: infer from the initial state.
                else -> if (call.state == Call.STATE_RINGING) "incoming" else "outgoing"
            }
        }
    }

    private val callCallback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) {
            // Only the foreground call drives the screen state — a background
            // call flipping to HOLDING while the second call dials must not
            // repaint the UI as "on hold".
            if (call == currentCall) publishState(call, state)
            // Mergeability depends on the active/held mix — keep Flutter posted.
            publishCallsChanged()
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        Log.d(TAG, "onCallAdded state=${call.state}")

        // Blocked caller: reject immediately, show nothing. Telecom records
        // the rejected call in the call log (typed BLOCKED/REJECTED), so it
        // still appears in «اخیر» without ever ringing the user.
        if (call.state == Call.STATE_RINGING &&
            BlockedNumbers.isBlocked(applicationContext, phoneOf(call))
        ) {
            Log.d(TAG, "Rejecting call from blocked number")
            call.reject(false, null)
            return
        }

        calls.add(call)
        currentCall = call
        call.registerCallback(callCallback)
        publishState(call, call.state)
        publishCallsChanged()
        if (call.state == Call.STATE_RINGING) {
            postIncomingCallNotification(phoneOf(call))
        }
    }

    override fun onCallRemoved(call: Call) {
        super.onCallRemoved(call)
        call.unregisterCallback(callCallback)
        calls.remove(call)
        cancelIncomingCallNotification()

        // Default-dialer duty: the system dialer used to post the missed-call
        // notification — now that's on us.
        if (call.details?.disconnectCause?.code == DisconnectCause.MISSED) {
            postMissedCallNotification(phoneOf(call))
        }

        val remaining = topLevelCalls()
        if (remaining.isEmpty()) {
            // Last call gone — tear the in-call UI down.
            currentCall = null
            stickyState = null
            CallEventStreamHandler.sendEvent(
                CallEvent.DISCONNECTED,
                mapOf("phone" to phoneOf(call), "direction" to directionOf(call)),
            )
        } else {
            // Another call is still up (conference member ended, or one leg of
            // a two-call session hung up) — keep the UI on the survivor.
            val next = remaining.last()
            currentCall = next
            // A surviving held call is resumed so the user isn't left in
            // silence wondering where the audio went.
            if (next.state == Call.STATE_HOLDING) next.unhold()
            publishState(next, next.state)
        }
        publishCallsChanged()
    }

    /** Pushes the number of top-level calls + mergeability to Flutter. */
    private fun publishCallsChanged() {
        CallEventStreamHandler.sendRaw(
            mapOf(
                "event" to "CALLS_CHANGED",
                "count" to topLevelCalls().size,
                "canMerge" to canMerge(),
            ),
        )
    }

    override fun onCallAudioStateChanged(audioState: CallAudioState) {
        super.onCallAudioStateChanged(audioState)
        // Keep Flutter's speaker/mute toggles honest if the state is changed
        // elsewhere (e.g. bluetooth connects).
        CallEventStreamHandler.sendRaw(
            mapOf(
                "event" to "AUDIO_STATE",
                "speaker" to (audioState.route == CallAudioState.ROUTE_SPEAKER),
                "muted" to audioState.isMuted,
            ),
        )
    }

    /** Maps a telecom call state onto the app's CallEvent vocabulary. */
    private fun publishState(call: Call, state: Int) {
        val data = mapOf(
            "phone" to phoneOf(call),
            "direction" to directionOf(call),
        )
        val event = when (state) {
            Call.STATE_RINGING -> CallEvent.INCOMING
            Call.STATE_DIALING, Call.STATE_CONNECTING -> CallEvent.RINGING
            Call.STATE_ACTIVE -> {
                cancelIncomingCallNotification()
                CallEvent.ACTIVE
            }
            Call.STATE_HOLDING -> CallEvent.ON_HOLD
            Call.STATE_DISCONNECTED -> {
                cancelIncomingCallNotification()
                CallEvent.DISCONNECTED
            }
            else -> return
        }
        stickyState = if (event == CallEvent.DISCONNECTED) {
            null
        } else {
            data + mapOf("event" to event.name)
        }
        CallEventStreamHandler.sendEvent(event, data)
    }

    // ── Multi-call control (called from CallHandler) ────────────────────────

    /** Merges the active and held calls into a conference (تماس گروهی). */
    fun mergeCalls() {
        val top = topLevelCalls()
        val active = top.firstOrNull { it.state == Call.STATE_ACTIVE }
        val held = top.firstOrNull { it.state == Call.STATE_HOLDING }
        when {
            active != null && held != null -> active.conference(held)
            else -> top.firstOrNull {
                it.details?.can(Call.Details.CAPABILITY_MERGE_CONFERENCE) == true
            }?.mergeConference()
        }
    }

    /** Swaps the active and held calls (telecom holds the active one itself). */
    fun swapCalls() {
        val top = topLevelCalls()
        val held = top.firstOrNull { it.state == Call.STATE_HOLDING } ?: return
        currentCall = held
        held.unhold()
        publishState(held, held.state)
    }

    // ── Audio control (called from CallHandler) ─────────────────────────────

    fun setSpeaker(on: Boolean) {
        setAudioRoute(
            if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_WIRED_OR_EARPIECE,
        )
    }

    fun setMicMuted(muted: Boolean) = setMuted(muted)

    // ── Incoming-call notification (full-screen intent) ─────────────────────

    /**
     * High-priority notification with a fullScreenIntent: when the app process
     * is dead or backgrounded, this is what launches MainActivity so Flutter
     * can show IncomingCallScreen. Answer/decline actions work straight from
     * the notification shade too.
     */
    private fun postIncomingCallNotification(phone: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "تماس ورودی", NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "اعلان تماس‌های ورودی"
                    setSound(null, null) // telecom already plays the ringtone
                    enableVibration(false)
                },
            )
        }

        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("incoming_call", phone)
        } ?: Intent()
        val fullScreen = PendingIntent.getActivity(this, 0, launch, piFlags)

        val answer = PendingIntent.getBroadcast(
            this, 1,
            Intent(CallActionReceiver.ACTION_ANSWER).setPackage(packageName), piFlags,
        )
        val decline = PendingIntent.getBroadcast(
            this, 2,
            Intent(CallActionReceiver.ACTION_DECLINE).setPackage(packageName), piFlags,
        )

        val name = lookupContactName(phone) ?: phone
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(name)
            .setContentText("تماس ورودی")
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setFullScreenIntent(fullScreen, true)
            .setContentIntent(fullScreen)
            .addAction(0, "رد", decline)
            .addAction(0, "پاسخ", answer)
            .build()
        nm.notify(NOTIF_ID, notification)
    }

    private fun cancelIncomingCallNotification() {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(NOTIF_ID)
    }

    /** «تماس بی‌پاسخ» — tap opens the app on the recents tab. */
    private fun postMissedCallNotification(phone: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    MISSED_CHANNEL_ID, "تماس بی‌پاسخ",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = "اعلان تماس‌های بی‌پاسخ" },
            )
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        } ?: Intent()
        val contentIntent = PendingIntent.getActivity(this, 3, launch, piFlags)

        val name = lookupContactName(phone) ?: phone
        // Unique id per event so several missed calls stack instead of
        // overwriting each other.
        val notifId = (System.currentTimeMillis() and 0x7FFFFFFF).toInt()
        nm.notify(
            notifId,
            NotificationCompat.Builder(this, MISSED_CHANNEL_ID)
                .setSmallIcon(applicationInfo.icon)
                .setContentTitle("تماس بی‌پاسخ")
                .setContentText(name)
                .setCategory(NotificationCompat.CATEGORY_MISSED_CALL)
                .setAutoCancel(true)
                .setContentIntent(contentIntent)
                .build(),
        )
    }

    private fun lookupContactName(phone: String): String? {
        if (phone.isEmpty()) return null
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phone),
            )
            contentResolver.query(
                uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (e: Exception) {
            null
        }
    }
}

/** Answers/declines the ringing call from the notification actions. */
class CallActionReceiver : android.content.BroadcastReceiver() {
    companion object {
        const val ACTION_ANSWER = "com.example.communication_super_app.ANSWER_CALL"
        const val ACTION_DECLINE = "com.example.communication_super_app.DECLINE_CALL"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val call = CallInCallService.currentCall ?: return
        when (intent.action) {
            ACTION_ANSWER -> {
                call.answer(VideoProfile.STATE_AUDIO_ONLY)
                // Bring the in-call UI up behind the shade.
                context.packageManager.getLaunchIntentForPackage(context.packageName)
                    ?.apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP }
                    ?.let { context.startActivity(it) }
            }
            // reject() only works while RINGING; disconnect covers the rest.
            ACTION_DECLINE ->
                if (call.state == Call.STATE_RINGING) {
                    call.reject(false, null)
                } else {
                    call.disconnect()
                }
        }
    }
}
