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
import com.example.communication_super_app.sim.SimRegistry
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
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
        private const val SILENT_CHANNEL_ID = "incoming_call_silent_channel"
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

        /** Every telecom call currently bound (conference children included).
         *  NOT named `calls` — that would be shadowed inside the service by the
         *  framework's InCallService.getCalls() (an unmodifiable list), and
         *  `calls.add(...)` would crash with UnsupportedOperationException. */
        @JvmStatic
        val trackedCalls = java.util.concurrent.CopyOnWriteArrayList<Call>()

        /** Calls that are not children of a conference — what the UI counts. */
        @JvmStatic
        fun topLevelCalls(): List<Call> = trackedCalls.filter { it.parent == null }

        /** True while any call is still up (ringing, dialling or connected).
         *  Drives MainActivity's show-over-the-lock-screen window flags. */
        @JvmStatic
        fun hasLiveCall(): Boolean =
            trackedCalls.any { it.state != Call.STATE_DISCONNECTED }

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

        /**
         * True for a dialed string telephony handles as an **MMI/USSD code**
         * («*100#», «*140*11#», «*#06#», «**21*شماره#») rather than as a voice
         * call — the same rule AOSP's `TelephonyConnectionService` applies:
         * starts with `*` or `#` **and** ends with `#`.
         *
         * The trailing `#` matters. «#31#09121234567» is an MMI *prefix* on a
         * real call (per-call caller-ID suppression) and must keep the normal
         * call UI, which this correctly reports as false.
         */
        @JvmStatic
        fun isMmiCode(number: String): Boolean {
            val n = number.trim()
            return n.length >= 2 &&
                (n.startsWith("*") || n.startsWith("#")) &&
                n.endsWith("#")
        }

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

    /** True once the Flutter call screen has been on screen for the current
     *  ringing call — see [onCallUiVisible]. Reset per call. */
    @Volatile
    private var callUiShown = false

    private val callCallback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) {
            // Answered / rejected: the «تماس ورودی» card has nothing left to
            // offer and would otherwise sit in the shade for the whole call.
            if (state != Call.STATE_RINGING &&
                trackedCalls.none { it.state == Call.STATE_RINGING }
            ) {
                cancelIncomingCallNotification()
            }
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

        // USSD/MMI: telephony answers it itself (com.android.phone puts the
        // network's reply in its own dialog) and destroys the connection within
        // a few hundred ms. It is NOT a call, so it must not be tracked: doing
        // so flashed the in-call screen up and pulled the activity to the front
        // — twice, counting the 2 s Samsung re-assert below — right over the
        // USSD dialog the user is meant to read.
        if (isMmiCode(phoneOf(call))) {
            Log.d(TAG, "Ignoring MMI/USSD dial — telephony owns the UI")
            return
        }

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

        trackedCalls.add(call)
        currentCall = call
        callUiShown = false
        call.registerCallback(callCallback)
        publishState(call, call.state)
        publishCallsChanged()
        // A live activity has to be told to move over the keyguard *before*
        // the full-screen intent brings it forward, or it comes up behind the
        // lock screen (black screen, phone still ringing).
        com.example.communication_super_app.MainActivity.instance
            ?.showOverLockScreen(true)
        if (call.state == Call.STATE_RINGING) {
            // App on screen → the Flutter IncomingCallScreen is already being
            // pushed by the INCOMING event; post only a silent shade entry (no
            // heads-up popup over the in-app UI). Backgrounded/dead → the
            // high-priority notification (with its fullScreenIntent) IS the
            // incoming-call UI.
            val backgrounded =
                !com.example.communication_super_app.MainActivity.isResumed
            postIncomingCallNotification(phoneOf(call), headsUp = backgrounded)
            // Belt and braces: OEMs throttle full-screen intents, and a
            // throttled one leaves the user staring at the lock screen. Ask for
            // the activity ourselves too — it is singleTop, so the worst case is
            // an extra onNewIntent.
            if (backgrounded) bringActivityToFront()
        } else {
            // Outgoing call: the default-dialer contract expects the UI dialer
            // to LAUNCH its in-call activity itself. Without a formal activity
            // start, Samsung's SCallUI fallback ("isTopActivity: false")
            // launches the OEM in-call screen ~800ms in and covers this app.
            bringActivityToFront()
            // Samsung One UI binds its own InCallServiceImpl regardless and
            // launches the OEM screen ~1s in, covering us. Re-assert once after
            // it settles; SCallUI does not re-launch once its activity exists,
            // so this doesn't ping-pong.
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                if (trackedCalls.contains(call) &&
                    call.state != Call.STATE_DISCONNECTED
                ) {
                    bringActivityToFront()
                }
            }, 2000)
        }
    }

    /**
     * The Flutter call screen came to the front (or left it) — MainActivity's
     * onResume / onPause.
     *
     * While it is visible the incoming-call notification is **cancelled**, not
     * merely silenced. On a locked-but-awake phone the activity is not resumed
     * when the call arrives, so the heads-up card is posted, and a silent
     * re-post is not enough: every notification is listed on the lock screen,
     * so the user saw the card *and* the call screen. Google Phone shows the
     * screen alone. It comes back (silent) the moment the user leaves.
     */
    fun onCallUiVisible(visible: Boolean) {
        val ringing = trackedCalls.firstOrNull { it.state == Call.STATE_RINGING }
            ?: return
        if (visible) {
            callUiShown = true
            cancelIncomingCallNotification()
        } else if (!callUiShown) {
            // Only ever posted back BEFORE the call screen has been seen. The
            // activity is started and stopped several times while coming up
            // over a keyguard, and re-posting on each stop is what put the card
            // back next to the call screen. Once the screen has been up for
            // this call, the card stays gone.
            postIncomingCallNotification(phoneOf(ringing), headsUp = false)
        }
    }

    /** Brings MainActivity to the foreground so the Flutter in-call UI is the
     *  visible (and telecom-recognized) call screen. */
    private fun bringActivityToFront() {
        try {
            packageManager.getLaunchIntentForPackage(packageName)?.apply {
                // NO_ANIMATION: the window open animation replays the app's
                // last frame (inbox / PIN screen) before the call screen is
                // pushed, which reads as the wrong screen flashing up.
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION
            }?.let { startActivity(it) }
        } catch (e: Exception) {
            Log.e(TAG, "bringActivityToFront failed: ${e.message}")
        }
    }

    override fun onCallRemoved(call: Call) {
        super.onCallRemoved(call)
        // Never added by onCallAdded (an MMI dial, or a blocked caller rejected
        // on arrival): there is no UI state to tear down, and running the rest
        // would publish a DISCONNECTED for a call the app never announced —
        // which, with a real call also up, would repaint the live call's screen.
        if (!trackedCalls.contains(call)) return
        call.unregisterCallback(callCallback)
        trackedCalls.remove(call)
        cancelIncomingCallNotification()

        // Default-dialer duty: the system dialer used to post the missed-call
        // notification — now that's on us.
        if (call.details?.disconnectCause?.code == DisconnectCause.MISSED) {
            postMissedCallNotification(
                phoneOf(call),
                SimRegistry.subscriptionIdForAccountId(
                    this,
                    call.details?.accountHandle?.id,
                ) ?: -1,
            )
        }

        val remaining = topLevelCalls()
        if (remaining.isEmpty()) {
            // Last call gone — tear the in-call UI down and stop showing the
            // app over the keyguard (the inbox must stay behind the app lock).
            com.example.communication_super_app.MainActivity.instance
                ?.showOverLockScreen(false)
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
            // Resolved HERE, not in Dart: a PhoneLookup is a single indexed
            // query, while the Dart side had to walk the whole address book,
            // so the call screen came up showing the bare number and swapped
            // in the name a beat later.
            "name" to lookupContactName(phoneOf(call)),
            "direction" to directionOf(call),
            // Conference host call (merged تماس گروهی) — the UI shows a group
            // title instead of the first participant's name.
            "isConference" to
                (call.details?.hasProperty(Call.Details.PROPERTY_CONFERENCE) == true),
            // Which SIM the call is on. Telecom names the account, not the
            // subscription, so it is mapped back here — the same mapping the
            // call log uses. -1 for a VoIP account or an unreadable roster,
            // which the UI renders as no badge rather than a guessed SIM.
            "subscriptionId" to (
                SimRegistry.subscriptionIdForAccountId(
                    this,
                    call.details?.accountHandle?.id,
                ) ?: -1
            ),
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
     * Incoming-call notification, two flavors:
     *
     * - [headsUp] = true (app backgrounded/dead): high-priority with a
     *   fullScreenIntent — this is what launches MainActivity so Flutter can
     *   show IncomingCallScreen.
     * - [headsUp] = false (IncomingCallScreen already on screen): silent
     *   entry in the notification shade only — no heads-up popup over the
     *   in-app UI, but still there with answer/decline if the user leaves the
     *   call screen.
     */
    private fun postIncomingCallNotification(phone: String, headsUp: Boolean = true) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = if (headsUp) CHANNEL_ID else SILENT_CHANNEL_ID
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = if (headsUp) {
                NotificationChannel(
                    CHANNEL_ID, "تماس ورودی", NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "اعلان تماس‌های ورودی"
                    setSound(null, null) // telecom already plays the ringtone
                    enableVibration(false)
                }
            } else {
                NotificationChannel(
                    SILENT_CHANNEL_ID, "تماس ورودی (بی‌صدا)",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "اعلان بی‌صدای تماس ورودی وقتی صفحه تماس باز است"
                    setSound(null, null)
                    enableVibration(false)
                }
            }
            nm.createNotificationChannel(channel)
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
        // CallStyle, not a plain notification with two actions: from Android 12
        // on it is what gets the ranked-to-the-top call treatment, and on a
        // locked screen it is what shows real پاسخ/رد buttons. That matters even
        // when the full-screen intent is throttled — the call stays answerable.
        val caller = Person.Builder().setName(name).setImportant(true).build()
        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(name)
            .setContentText("تماس ورودی")
            .setStyle(
                NotificationCompat.CallStyle.forIncomingCall(caller, decline, answer),
            )
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(
                if (headsUp) {
                    NotificationCompat.PRIORITY_MAX
                } else {
                    NotificationCompat.PRIORITY_LOW
                },
            )
            .setOngoing(true)
            // Lock screen shows the caller: the notification carries no message
            // content, and hiding it would leave an empty card to answer from.
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            // ALWAYS set, both flavors. A CallStyle notification that is
            // neither tied to a foreground service nor carrying a full-screen
            // intent is REJECTED with IllegalArgumentException — which killed
            // the process (and with it the InCallService, so the OEM dialer
            // took the call over). Whether it actually opens the activity is
            // decided by the channel importance, not by this flag: the silent
            // channel is IMPORTANCE_LOW, so it never fires.
            .setFullScreenIntent(fullScreen, headsUp)
            .setContentIntent(fullScreen)
            .build()
        // A rejected notification must never take the process down with it:
        // this service IS the call UI, so a crash here hands the call to the
        // OEM dialer.
        try {
            nm.notify(NOTIF_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "incoming-call notification rejected: ${e.message}")
        }
    }

    private fun cancelIncomingCallNotification() {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(NOTIF_ID)
    }

    /** «تماس بی‌پاسخ» — tap opens the app on the recents tab. */
    private fun postMissedCallNotification(phone: String, subscriptionId: Int) {
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
                // Which card was rung — the same subtext the SMS shade shows,
                // and absent on a single-SIM phone.
                .apply {
                    if (SimRegistry.isMultiSim(this@CallInCallService)) {
                        SimRegistry.labelOf(this@CallInCallService, subscriptionId)
                            ?.let { setSubText(it) }
                    }
                }
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
        val call = CallInCallService.currentCall
        Log.d("CallActionReceiver", "action=${intent.action} call=${call != null} state=${call?.state}")
        if (call == null) return
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
