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
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log
import com.example.communication_super_app.sim.SimRegistry
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import com.example.communication_super_app.BlockedNumbers
import com.example.communication_super_app.R

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
        private const val ONGOING_CHANNEL_ID = "ongoing_call_channel"
        private const val NOTIF_ID = 7001

        /** «تماس در جریان» — the card that keeps a minimized call reachable. */
        private const val ONGOING_NOTIF_ID = 7002

        /**
         * Whether the Flutter call screen is *mounted* (not minimized).
         *
         * Distinct from [callUiForeground]: the user can leave the call screen
         * without leaving the app — that is the whole point of being able to
         * look up a contact mid-call — and only Dart knows it happened. Set
         * over the call method channel («setCallScreenVisible»).
         */
        @JvmStatic
        @Volatile
        var callRouteUp = false

        /** [callRouteUp] as it last was while a call was live. */
        @Volatile
        private var routeUpDuringCall = false

        /** Whether MainActivity is between onStart and onStop. */
        @JvmStatic
        @Volatile
        var callUiForeground = false

        /** True only when the call screen is really in front of the user. */
        @JvmStatic
        fun callScreenShowing(): Boolean = callRouteUp && callUiForeground

        /**
         * Flutter reporting whether its in-call route is on screen.
         *
         * Posting/cancelling the ongoing-call card is driven from here as well
         * as from the activity lifecycle, because minimizing the call inside a
         * foreground app produces no lifecycle callback at all.
         */
        @JvmStatic
        fun setCallScreenVisible(visible: Boolean) {
            callRouteUp = visible
            // Only while a call is live: the report Dart sends as the call ends
            // must not erase whether the screen was up when it ended.
            if (hasLiveCall()) routeUpDuringCall = visible
            if (!visible && hasLiveCall()) {
                com.example.communication_super_app.MainActivity.instance
                    ?.yieldToKeyguard()
            }
            instance?.refreshOngoingNotification()
            instance?.syncIncomingNotification()
        }

        /** Extra on the incoming-call card's tap / full-screen intent. */
        const val EXTRA_INCOMING_CALL = "incoming_call"

        /** Extra on the launcher intent the ongoing-call card taps into. */
        const val EXTRA_RETURN_TO_CALL = "return_to_call"

        /** Missed-call ids live in their own range, one slot per caller. */
        private const val MISSED_ID_BASE = 7100

        /** Missed calls per caller since the shade was last cleared, so the
         *  card can say «۳ تماس بی‌پاسخ» instead of appearing three times. */
        private val missedCounts = java.util.concurrent.ConcurrentHashMap<String, Int>()

        /** Where [markMissedCall] keeps its marks — survives process death,
         *  because the carrier's SMS often arrives after the app is gone. */
        private const val MISSED_MARKS = "missed_call_marks"

        /** How long a mark makes the carrier's SMS redundant. The operator
         *  sends it within a minute or two; beyond this it is news again. */
        private const val MISSED_MARK_TTL_MS = 30L * 60_000

        /**
         * Records that this app has just told the user about a missed call
         * from [phone].
         *
         * Iranian operators also send a **text message** about the same missed
         * call («تعداد ۱ تماس از 0912… داشته‌اید»), from an alphanumeric sender
         * the app cannot call back. As the default dialer *and* the default SMS
         * app, this app posted both — which is the reported "one missed call,
         * two notifications, and the one labelled «تماس» goes nowhere". The
         * message is still delivered and still lands in the inbox; only the
         * duplicate *notification* is dropped. See
         * [SmsNotifier.isRedundantMissedCallSms].
         */
        @JvmStatic
        fun markMissedCall(context: Context, phone: String) {
            val key = BlockedNumbers.normalizeToThreadId(phone)
            if (key.isEmpty()) return
            try {
                val prefs = context.getSharedPreferences(MISSED_MARKS, Context.MODE_PRIVATE)
                val now = System.currentTimeMillis()
                val editor = prefs.edit().putLong(key, now)
                // Marks are tiny but they must not accumulate for ever.
                for ((k, v) in prefs.all) {
                    val at = v as? Long ?: continue
                    if (now - at > MISSED_MARK_TTL_MS) editor.remove(k)
                }
                editor.apply()
            } catch (e: Exception) {
                Log.d(TAG, "markMissedCall: ${e.message}")
            }
        }

        /** Whether a missed call from [phone] was announced within the TTL. */
        @JvmStatic
        fun wasMissedRecently(context: Context, phone: String): Boolean {
            val key = BlockedNumbers.normalizeToThreadId(phone)
            if (key.isEmpty()) return false
            return try {
                val at = context
                    .getSharedPreferences(MISSED_MARKS, Context.MODE_PRIVATE)
                    .getLong(key, 0L)
                at > 0 && System.currentTimeMillis() - at <= MISSED_MARK_TTL_MS
            } catch (e: Exception) {
                false
            }
        }

        /**
         * Dismisses every missed-call notification this app posted.
         *
         * Called when «اخیر» comes on screen: the user is looking at the list
         * the notification points at, so the notification has nothing left to
         * say. It also clears telecom's (and with it the OEM dialer's).
         */
        @JvmStatic
        fun clearMissedCallNotifications(context: Context) {
            try {
                cancelMissedCallCards(context)
                val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                tm.cancelMissedCallsNotification()
                // Telecom now hands the notification duty to this app (see
                // MissedCallNotificationReceiver), and with it a "these have
                // been seen" intent. Firing it is what clears the platform's
                // own unread-missed-call count — the launcher badge and the
                // call log's NEW flag — which `cancelMissedCallsNotification`
                // alone does not always reach on an OEM build.
                MissedCallNotificationReceiver.clearPlatformMissedCalls()
            } catch (e: Exception) {
                Log.d(TAG, "clearMissedCallNotifications: ${e.message}")
            }
        }

        /**
         * Takes down this app's missed-call cards and **tells nobody**.
         *
         * The half of [clearMissedCallNotifications] that is safe to call from
         * inside a `SHOW_MISSED_CALLS_NOTIFICATION` handler: telecom asking us
         * to clear must not make us ask telecom to clear, or the two bounce the
         * broadcast between them for ever.
         */
        @JvmStatic
        fun cancelMissedCallCards(context: Context) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    nm.activeNotifications
                        .filter { it.id >= MISSED_ID_BASE && it.id < MISSED_ID_BASE + 0x10000 }
                        .forEach { nm.cancel(it.tag, it.id) }
                }
                missedCounts.clear()
            } catch (e: Exception) {
                Log.d(TAG, "cancelMissedCallCards: ${e.message}")
            }
        }

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

        /**
         * States in which a call is something the UI must keep showing.
         *
         * NEW and DISCONNECTED are deliberately out. Telecom adds calls in
         * STATE_NEW (Samsung adds several while a conference settles) and
         * leaves disconnected ones bound for a moment, and counting either as
         * live is what left the call screen up with the timer still running
         * after the call had ended: `onCallRemoved` found a "remaining" call
         * that was really a corpse and never published DISCONNECTED. A NEW
         * call announces itself again through `onStateChanged` the instant it
         * becomes real, so nothing is lost by ignoring it here.
         */
        private val LIVE_STATES = setOf(
            Call.STATE_SELECT_PHONE_ACCOUNT,
            Call.STATE_CONNECTING,
            Call.STATE_DIALING,
            Call.STATE_RINGING,
            Call.STATE_ACTIVE,
            Call.STATE_HOLDING,
            Call.STATE_PULLING_CALL,
            Call.STATE_SIMULATED_RINGING,
        )

        @JvmStatic
        fun isLive(call: Call): Boolean = call.state in LIVE_STATES

        /**
         * The call the UI should follow once [ending] is gone, or null when
         * the phone is about to be idle.
         *
         * An ACTIVE call wins over a held or ringing one: it is the
         * conversation the user is actually having, and the point of asking is
         * to keep the screen on it rather than on the leg that just dropped.
         */
        @JvmStatic
        fun liveSuccessorTo(ending: Call): Call? {
            val top = topLevelCalls().filter { it !== ending }
            return top.firstOrNull { it.state == Call.STATE_ACTIVE }
                ?: top.lastOrNull()
        }

        /**
         * The call an in-call keypad press must reach: the one that is ACTIVE.
         *
         * [currentCall] first when it is active (the common case, and a
         * conference host is top-level and active), then any active top-level
         * call we track, then telecom's own list — the authoritative one, in
         * case a call was ever bound without passing through [onCallAdded].
         * Null when nothing is active: a held, ringing or dialling call cannot
         * carry DTMF, and telecom drops a tone sent to one without a word.
         */
        @JvmStatic
        fun dtmfTarget(): Call? {
            currentCall?.takeIf { it.state == Call.STATE_ACTIVE }?.let { return it }
            topLevelCalls().firstOrNull { it.state == Call.STATE_ACTIVE }
                ?.let { return it }
            return instance?.calls?.firstOrNull {
                it.parent == null && it.state == Call.STATE_ACTIVE
            }
        }

        /** Live calls that are not children of a conference — what the UI counts. */
        @JvmStatic
        fun topLevelCalls(): List<Call> =
            trackedCalls.filter { it.parent == null && isLive(it) }

        /** True while any call is still up (ringing, dialling or connected).
         *  Drives MainActivity's show-over-the-lock-screen window flags. */
        @JvmStatic
        fun hasLiveCall(): Boolean =
            trackedCalls.any { it.state != Call.STATE_DISCONNECTED }

        /** A call is ringing and has to be answerable — the ONE case where the
         *  screen is forced to stay on. Once answered the proximity sensor
         *  owns the display; see [ProximityGate]. */
        @JvmStatic
        fun hasRingingCall(): Boolean =
            trackedCalls.any { it.state == Call.STATE_RINGING }

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
         * Whether this call arrives with no usable caller id — «خصوصی»,
         * «ناشناس», a payphone, or a number telecom simply could not present.
         *
         * Both halves are needed. `handlePresentation` is the authoritative
         * answer and is what a withheld number sets, but some networks and OEM
         * builds present `PRESENTATION_ALLOWED` with an empty handle instead,
         * which reads to every other part of this app as "unknown caller" too.
         * Anything with digits in it is left alone whatever the presentation
         * says: refusing a call that *can* be identified is the blocked list's
         * job, not this rule's.
         */
        private fun isUnidentified(call: Call): Boolean {
            val details = call.details ?: return false
            if (phoneOf(call).any { it.isDigit() }) return false
            val presentation = runCatching { details.handlePresentation }
                .getOrDefault(TelecomManager.PRESENTATION_ALLOWED)
            return presentation == TelecomManager.PRESENTATION_RESTRICTED ||
                presentation == TelecomManager.PRESENTATION_PAYPHONE ||
                presentation == TelecomManager.PRESENTATION_UNKNOWN ||
                phoneOf(call).isBlank()
        }

        /**
         * Creates the three call channels.
         *
         * Called from `MainActivity.onCreate` as well as from the post paths,
         * so the channels exist *before* the first call — otherwise
         * [areCallNotificationsEnabled] cannot tell "the user switched this
         * off" from "never created", and the app cannot warn about the one
         * setting that makes every incoming call invisible.
         */
        @JvmStatic
        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "تماس ورودی", NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "اعلان تماس‌های ورودی"
                    setSound(null, null) // telecom already plays the ringtone
                    enableVibration(false)
                },
            )
            nm.createNotificationChannel(
                NotificationChannel(
                    SILENT_CHANNEL_ID, "تماس ورودی (بی‌صدا)",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "اعلان بی‌صدای تماس ورودی وقتی صفحه تماس باز است"
                    setSound(null, null)
                    enableVibration(false)
                },
            )
            nm.createNotificationChannel(
                NotificationChannel(
                    MISSED_CHANNEL_ID, "تماس بی‌پاسخ",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = "اعلان تماس‌های بی‌پاسخ" },
            )
            // LOW: it must never pop a heads-up over whatever the user left
            // the call screen to do — it is a way back, not an interruption.
            nm.createNotificationChannel(
                NotificationChannel(
                    ONGOING_CHANNEL_ID, "تماس در جریان",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "اعلان تماس فعال برای بازگشت به صفحه تماس"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                },
            )
        }

        /**
         * Whether an incoming call can produce anything the user can see.
         *
         * This is the gate that fails silently: with notifications off (or the
         * «تماس ورودی» channel muted) the CallStyle card is dropped AND its
         * full-screen intent never fires, so a locked phone rings with no way
         * to answer — which is exactly the "only the ringtone, no picture"
         * report. Nothing in the call path can detect that from the inside;
         * the app has to ask and tell the user.
         */
        @JvmStatic
        fun areCallNotificationsEnabled(context: Context): Boolean = try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            when {
                !nm.areNotificationsEnabled() -> false
                Build.VERSION.SDK_INT < Build.VERSION_CODES.O -> true
                else -> {
                    val channel = nm.getNotificationChannel(CHANNEL_ID)
                    // A channel that does not exist yet is not "blocked" — it
                    // will be created at its requested importance.
                    channel == null ||
                        channel.importance != NotificationManager.IMPORTANCE_NONE
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "notification check failed: ${e.message}")
            true
        }

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

    /**
     * The ringing call that gets the **full incoming-call screen**; any other
     * ringing call is announced by the heads-up card alone.
     *
     * This is Google Phone's split, and it is not a setting — it follows from
     * what the user is doing when the call arrives:
     *
     *  * **the phone is in use** (screen on, unlocked) → the card drops in at
     *    the top of whatever they are doing, with «پاسخ» / «رد» on it. Taking
     *    over the screen in the middle of somebody's typing is the thing a
     *    heads-up exists to avoid. It is the system that draws it: the card
     *    carries a full-screen intent, and SystemUI shows a full-screen
     *    intent as a heads-up while the device is in use.
     *  * **the phone is not in use** (screen off, or locked) → the full
     *    screen, which is also the only thing that can be answered from a
     *    keyguard without hunting for a notification.
     *  * **the call screen is already in front** (a second call ringing
     *    during a call) → the incoming screen in place, as Google's in-call
     *    activity does.
     *
     * A call announced by the card is promoted here when the user taps the
     * card ([showIncomingScreen]) or the phone is locked while it rings
     * ([onScreenOn]). Published with the RINGING state as `showScreen`, so a
     * cold-started engine replays the decision rather than guessing it.
     */
    @Volatile
    private var incomingScreenCall: Call? = null

    /** Whether this app was on screen when the current call started ringing —
     *  where «back» out of its incoming screen should return to. */
    @Volatile
    private var appInFrontAtRing = false

    /**
     * The session started with a call ringing in while this app was NOT on
     * screen, so the app is only in front because of the call. When the last
     * call ends with its screen still up, the user goes back to what they
     * were doing — Google Phone's in-call activity simply finishes — rather
     * than being left inside this app's tabs. See [onCallRemoved].
     */
    @Volatile
    private var returnWhenOver = false

    /** Watches the screen coming back on while a call rings on the card
     *  only — see [onScreenOn]. Registered only while something rings. */
    private var screenOnReceiver: android.content.BroadcastReceiver? = null

    /** Last CALLS_CHANGED / call-state payloads, so the burst of callbacks a
     *  merge produces collapses into the one event that actually changed
     *  something. */
    private var lastCallsPayload: Map<String, Any?>? = null
    private var lastStatePayload: Map<String, Any?>? = null

    private val callCallback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) {
            // Answered / rejected: the «تماس ورودی» card has nothing left to
            // offer and would otherwise sit in the shade for the whole call.
            if (state != Call.STATE_RINGING &&
                trackedCalls.none { it.state == Call.STATE_RINGING }
            ) {
                cancelIncomingCallNotification()
            }
            if (state != Call.STATE_RINGING) {
                if (incomingScreenCall === call) incomingScreenCall = null
                if (!hasRingingCall()) unwatchScreenOn()
            }
            // Only the foreground call drives the screen state — a background
            // call flipping to HOLDING while the second call dials must not
            // repaint the UI as "on hold".
            //
            // …and the call the UI is following ending is only the END of the
            // call when nothing else is left. Call waiting makes the *second*
            // (ringing) call `currentCall`, so the far more common case — the
            // waiting caller gives up while the user keeps talking — arrived
            // here as DISCONNECTED for `currentCall` and published "the call is
            // over" while the user was still on the line. The survivor takes
            // over instead; only an empty phone publishes DISCONNECTED.
            if (call == currentCall) {
                val survivor = if (state == Call.STATE_DISCONNECTED) {
                    liveSuccessorTo(call)
                } else {
                    null
                }
                if (survivor != null) {
                    currentCall = survivor
                    publishState(survivor, survivor.state)
                } else {
                    publishState(call, state)
                }
            }
            // Mergeability depends on the active/held mix — keep Flutter posted.
            publishCallsChanged()
            // Answered / put on hold / ended — whether the ear may blank the
            // screen changes with every one of those, and so does the
            // keep-screen-on flag (held only while RINGING).
            ProximityGate.refresh(applicationContext)
            com.example.communication_super_app.MainActivity.instance
                ?.syncLockScreenVisibility()
            // Answered / held / ended — each changes whether there is a call to
            // offer a way back to, and what its duration counts from.
            refreshOngoingNotification()
            // Nothing live is left, but the call this state belongs to is not
            // the one the UI is following (it hung up while a stale STATE_NEW
            // placeholder was `currentCall`): tear the screen down here rather
            // than waiting for an onCallRemoved that may never single out the
            // right call.
            if (topLevelCalls().isEmpty()) republishCurrent()
        }

        /**
         * The call became (or stopped being) a child of a conference.
         *
         * This is THE signal that a merge finished. Telecom sets the parent
         * link *after* [onCallAdded] delivered the conference host, so a UI
         * that only counts calls when a call is added or changes state kept
         * counting the two legs as top-level and left «ادغام تماس» on screen
         * over an already-merged call.
         */
        override fun onParentChanged(call: Call, parent: Call?) {
            publishCallsChanged()
            republishCurrent()
        }

        /** The conference gained/lost a participant — same reasoning. */
        override fun onChildrenChanged(call: Call, children: MutableList<Call>) {
            publishCallsChanged()
            if (call == currentCall) republishCurrent()
        }

        /**
         * Capabilities and PROPERTY_CONFERENCE live in the details, and both
         * change without a state change: `canMerge` (CAPABILITY_MERGE_CONFERENCE)
         * and the «تماس گروهی» title are only correct if this is watched.
         */
        override fun onDetailsChanged(call: Call, details: Call.Details) {
            publishCallsChanged()
            if (call == currentCall) republishCurrent()
        }

        /** Telecom re-evaluated which calls may be conferenced together. */
        override fun onConferenceableCallsChanged(
            call: Call,
            conferenceableCalls: MutableList<Call>,
        ) {
            publishCallsChanged()
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        // The service is the only owner of the proximity lock; leaving it held
        // would blank the phone with no call to explain it.
        ProximityGate.release()
        // An ongoing-call card outliving the service would point at a call that
        // no longer exists, with a «پایان» button bound to nothing.
        cancelOngoingCallNotification()
        unwatchScreenOn()
        incomingScreenCall = null
        callRouteUp = false
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

        // «تماس‌های ناشناس» — a caller who withheld their number cannot be put
        // in the blocked list at all (there is nothing to put there), so the
        // only way to refuse them is a rule. Off by default and read from a
        // native mirror of the setting, because this runs with no Flutter
        // engine as often as not. Google Phone's own «Unknown» switch, in the
        // same place and with the same default.
        if (call.state == Call.STATE_RINGING &&
            CallPrefs.blockUnknownCallers(applicationContext) &&
            isUnidentified(call)
        ) {
            Log.d(TAG, "Rejecting call from an unidentified caller")
            call.reject(false, null)
            return
        }

        trackedCalls.add(call)
        currentCall = call
        callUiShown = false
        lastStatePayload = null
        // Decided BEFORE the first publish — it rides on the RINGING payload.
        // See [incomingScreenCall].
        if (call.state == Call.STATE_RINGING) appInFrontAtRing = callUiForeground
        // The first call of a session decides where the phone goes when it is
        // all over — see [returnWhenOver].
        if (topLevelCalls().size <= 1) {
            returnWhenOver = call.state == Call.STATE_RINGING && !callUiForeground
        }
        if (call.state == Call.STATE_RINGING) {
            incomingScreenCall =
                if (callScreenShowing() || !deviceInUse()) call else null
        }
        call.registerCallback(callCallback)
        publishState(call, call.state)
        publishCallsChanged()
        // A live activity has to be told to move over the keyguard *before*
        // the full-screen intent brings it forward, or it comes up behind the
        // lock screen (black screen, phone still ringing).
        com.example.communication_super_app.MainActivity.instance
            ?.showOverLockScreen(true)

        // A conference host is not a new call the user placed — telecom adds it
        // when two existing calls merge, with the call UI already on screen.
        // Running the outgoing-call branch below for it launched MainActivity
        // twice (immediately and again 2 s later) on top of a live call: the
        // window animation, the Flutter route rebuild and the OEM re-assert all
        // ran for nothing, which is the stutter «تماس گروهی» had.
        if (call.details?.hasProperty(Call.Details.PROPERTY_CONFERENCE) == true) {
            Log.d(TAG, "Conference host added — UI is already up")
            return
        }

        if (call.state == Call.STATE_RINGING) {
            // Call screen already in front (call waiting): Flutter swaps in
            // the incoming screen itself, so the card is a silent shade entry.
            // Anything else gets the loud card — which the system shows as a
            // heads-up while the phone is in use and turns into the full
            // screen (its full-screen intent) while it is not.
            val inFront = callScreenShowing()
            postIncomingCallNotification(
                phoneOf(call),
                headsUp = !inFront,
                subscriptionId = subscriptionOf(call),
            )
            if (incomingScreenCall === call && !inFront) {
                // Belt and braces for the locked/asleep phone: OEMs throttle
                // full-screen intents, and a throttled one leaves the user
                // staring at the lock screen. It is singleTop, so the worst
                // case is an extra onNewIntent. NEVER for a phone in use —
                // that is exactly what used to force the full screen over
                // whatever the user was doing instead of the heads-up.
                bringActivityToFront()
            }
            if (incomingScreenCall !== call) watchScreenOn()
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
        callUiForeground = visible
        // A live call the user has walked away from needs its way back,
        // whether or not anything is ringing.
        refreshOngoingNotification()
        syncIncomingNotification()
    }

    /**
     * Keeps the incoming card in step with whether the incoming *screen* is
     * what the user is looking at.
     *
     * "The activity is in front" is no longer the same thing: a call rung on
     * the heads-up card leaves the app open on whatever the user was doing,
     * and the card is then the only way to answer — cancelling it on
     * `onStart` would leave a ringing phone with nothing to press. So it keys
     * on [callScreenShowing], which needs the Flutter call route up as well.
     */
    fun syncIncomingNotification() {
        val ringing = trackedCalls.firstOrNull { it.state == Call.STATE_RINGING }
            ?: return
        if (callScreenShowing()) {
            callUiShown = true
            if (incomingScreenCall !== ringing) {
                incomingScreenCall = ringing
                if (ringing == currentCall) publishState(ringing, ringing.state)
            }
            cancelIncomingCallNotification()
        } else if (callUiShown && !deviceInUse() && !callRouteUp) {
            // Backed out of the incoming screen on a LOCKED phone (MainActivity
            // then yields to the keyguard): the lock-screen card is the way to
            // answer now. Silent — a loud one would fire its full-screen intent
            // and throw the screen the user just left straight back at them.
            callUiShown = false
            postIncomingCallNotification(
                phoneOf(ringing),
                headsUp = false,
                subscriptionId = subscriptionOf(ringing),
            )
        } else if (callUiShown && deviceInUse()) {
            // The user saw the incoming screen and left it — Home, another
            // app, or back out of it — with the phone unlocked in their hand.
            // Google Phone hands the call back to the heads-up card at that
            // point; with no card at all the call could only be answered by
            // finding the app again. Gated on [deviceInUse] because over a
            // keyguard the activity is started and stopped several times while
            // staying perfectly visible, and re-posting on each of those stops
            // is what once put the card on the lock screen next to the call
            // screen. Reset so the next stop does not post it twice.
            callUiShown = false
            postIncomingCallNotification(
                phoneOf(ringing),
                headsUp = true,
                subscriptionId = subscriptionOf(ringing),
            )
            watchScreenOn()
            // Backed out (the route is gone, the activity is still in front) of
            // a screen the card had opened over some OTHER app: back means back
            // to that app, as in Google Phone — not to this app's own tabs,
            // which the user never asked to see.
            if (!callRouteUp && callUiForeground && !appInFrontAtRing) {
                com.example.communication_super_app.MainActivity.instance
                    ?.moveTaskToBack(true)
            }
        }
    }

    /**
     * The incoming card was tapped (or its full-screen intent fired): the user
     * wants the full incoming screen. Called by MainActivity for an intent
     * carrying [EXTRA_INCOMING_CALL].
     *
     * Both halves are needed. The republished RINGING state (`showScreen`) is
     * what a cold-started engine replays; the SHOW_CALL_UI request is what
     * re-opens the screen when the decision had already been made and the user
     * had merely backed out of it — a state that did not change is never
     * re-sent.
     */
    fun showIncomingScreen() {
        val ringing = trackedCalls.firstOrNull { it.state == Call.STATE_RINGING }
            ?: return
        if (incomingScreenCall !== ringing) {
            incomingScreenCall = ringing
            if (ringing == currentCall) publishState(ringing, ringing.state)
        }
        CallEventStreamHandler.sendRaw(mapOf("event" to "SHOW_CALL_UI"))
    }

    /**
     * The phone is being used: screen on and not locked. What decides between
     * the heads-up card and the full incoming screen — see [incomingScreenCall].
     */
    private fun deviceInUse(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        val keyguard =
            getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        return power.isInteractive && !keyguard.isKeyguardLocked
    }

    /**
     * The screen came back on while a call rings on the heads-up card alone.
     *
     * The card was shown because the phone was in use; if the user switched
     * the screen off instead of answering (the power key also silences the
     * ringer), the phone they wake is a *locked* phone, and a locked phone
     * gets the full screen — the same one a call that arrived while it was
     * locked gets. Promoted on SCREEN_ON rather than SCREEN_OFF: starting the
     * activity while the screen is off would switch it straight back on
     * (`setTurnScreenOn`), undoing the power press.
     */
    private fun onScreenOn() {
        val ringing = trackedCalls.firstOrNull { it.state == Call.STATE_RINGING }
        if (ringing == null) {
            unwatchScreenOn()
            return
        }
        if (callScreenShowing()) return
        val keyguard =
            getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        if (!keyguard.isKeyguardLocked) return
        Log.d(TAG, "Screen on over a ringing call — showing the incoming screen")
        showIncomingScreen()
        bringActivityToFront()
    }

    private fun watchScreenOn() {
        if (screenOnReceiver != null) return
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = onScreenOn()
        }
        try {
            // A protected system broadcast: no export flag is needed, and
            // passing one is refused on older releases.
            registerReceiver(receiver, android.content.IntentFilter(Intent.ACTION_SCREEN_ON))
            screenOnReceiver = receiver
        } catch (e: Exception) {
            Log.w(TAG, "screen-on watch not registered: ${e.message}")
        }
    }

    private fun unwatchScreenOn() {
        val receiver = screenOnReceiver ?: return
        screenOnReceiver = null
        try {
            unregisterReceiver(receiver)
        } catch (e: Exception) {
            Log.w(TAG, "screen-on watch not unregistered: ${e.message}")
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
        Log.d(TAG, "onCallRemoved state=${call.state} tracked=${trackedCalls.size}")
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

        // Only LIVE top-level calls keep the UI up — see LIVE_STATES. Telecom
        // keeps freshly-added STATE_NEW placeholders and just-disconnected legs
        // bound for a while, and treating one of those as "another call is
        // still up" is what left the call screen on screen, counting seconds,
        // after everyone had hung up.
        val remaining = topLevelCalls()
        ProximityGate.refresh(applicationContext)
        refreshOngoingNotification()
        if (remaining.isEmpty()) {
            // Last call gone — tear the in-call UI down and stop showing the
            // app over the keyguard (the inbox must stay behind the app lock).
            com.example.communication_super_app.MainActivity.instance
                ?.showOverLockScreen(false)
            currentCall = null
            stickyState = null
            lastStatePayload = null
            CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED, disconnectPayload(call))
            if (returnWhenOver && routeUpDuringCall && callUiForeground && deviceInUse()) {
                // After the beat Flutter lingers on the ended call (600 ms), and
                // only if nothing has started since and the user is still
                // looking at the call screen rather than something they opened.
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    if (topLevelCalls().isEmpty() && callUiForeground) {
                        com.example.communication_super_app.MainActivity.instance
                            ?.moveTaskToBack(true)
                    }
                }, 800)
            }
            returnWhenOver = false
        } else {
            // Another call is still up (conference member ended, or one leg of
            // a two-call session hung up) — keep the UI on the survivor. An
            // ACTIVE one is preferred over a held or ringing leg: it is the
            // conversation the user is in the middle of. Same choice as
            // [liveSuccessorTo], which the state callback makes a beat earlier.
            val next = liveSuccessorTo(call) ?: remaining.last()
            currentCall = next
            // A surviving held call is resumed so the user isn't left in
            // silence wondering where the audio went.
            if (next.state == Call.STATE_HOLDING) next.unhold()
            publishState(next, next.state)
        }
        publishCallsChanged()
    }

    /**
     * Re-sends the foreground call's state after a detail/parent/children
     * change.
     *
     * It must NOT publish for a call that is no longer live: those callbacks
     * keep firing on conference legs after everyone hung up, and re-announcing
     * a corpse as ACTIVE would put the call screen back over an idle phone —
     * the mirror image of the bug this whole section is about. With nothing
     * live left it publishes the DISCONNECTED that `onCallRemoved` may not have
     * had a chance to send yet.
     */
    private fun republishCurrent() {
        val call = currentCall ?: return
        if (isLive(call)) {
            publishState(call, call.state)
            return
        }
        if (topLevelCalls().isNotEmpty()) return
        currentCall = null
        stickyState = null
        lastStatePayload = null
        CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED, disconnectPayload(call))
    }

    /** Pushes the number of top-level calls + mergeability to Flutter.
     *
     *  De-duplicated: the details/parent/children callbacks fire in bursts
     *  while a merge settles, and re-posting an identical payload a dozen
     *  times is main-thread work on both sides of the channel for nothing —
     *  which is what the conference felt sluggish for. */
    private fun publishCallsChanged() {
        val payload = mapOf(
            "event" to "CALLS_CHANGED",
            "count" to topLevelCalls().size,
            "canMerge" to canMerge(),
        )
        if (payload == lastCallsPayload) return
        lastCallsPayload = payload
        CallEventStreamHandler.sendRaw(payload)
    }

    override fun onCallAudioStateChanged(audioState: CallAudioState) {
        super.onCallAudioStateChanged(audioState)
        // The screen may only blank against the ear while the audio actually
        // comes out of the earpiece.
        ProximityGate.onAudioRouteChanged(audioState, applicationContext)
        publishAudioState(audioState)
    }

    /**
     * Publishes the full audio picture, not just "speaker on/off".
     *
     * The route is an enumeration, not a boolean: a bluetooth headset is
     * neither speaker nor earpiece, and the picker cannot show which output is
     * live — or whether bluetooth is even an option — from one flag. The
     * supported mask is what tells «بلوتوث» from a row that would do nothing.
     */
    private fun publishAudioState(audioState: CallAudioState) {
        val mask = audioState.supportedRouteMask
        CallEventStreamHandler.sendRaw(
            mapOf(
                "event" to "AUDIO_STATE",
                "route" to routeName(audioState.route),
                // Kept for the plain speaker toggle, which is still a boolean.
                "speaker" to (audioState.route == CallAudioState.ROUTE_SPEAKER),
                "muted" to audioState.isMuted,
                "hasBluetooth" to
                    (mask and CallAudioState.ROUTE_BLUETOOTH != 0),
                "hasWiredHeadset" to
                    (mask and CallAudioState.ROUTE_WIRED_HEADSET != 0),
                "hasEarpiece" to (mask and CallAudioState.ROUTE_EARPIECE != 0),
                "bluetoothName" to bluetoothName(audioState),
            ),
        )
    }

    private fun routeName(route: Int): String = when (route) {
        CallAudioState.ROUTE_SPEAKER -> "speaker"
        CallAudioState.ROUTE_BLUETOOTH -> "bluetooth"
        CallAudioState.ROUTE_WIRED_HEADSET -> "wired"
        else -> "earpiece"
    }

    /** The connected headset's name, so the row reads «بلوتوث · Galaxy Buds»
     *  the way Google Phone's output picker does. Null when the platform will
     *  not say (needs BLUETOOTH_CONNECT on 31+, which this app does not ask
     *  for — the row still works, it just stays generic). */
    private fun bluetoothName(audioState: CallAudioState): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            audioState.activeBluetoothDevice?.name
        } else {
            null
        }
    } catch (e: SecurityException) {
        null
    }

    /** Explicit output selection from the picker. */
    fun setAudioRouteByName(name: String) {
        val route = when (name) {
            "speaker" -> CallAudioState.ROUTE_SPEAKER
            "bluetooth" -> CallAudioState.ROUTE_BLUETOOTH
            "wired" -> CallAudioState.ROUTE_WIRED_HEADSET
            else -> CallAudioState.ROUTE_EARPIECE
        }
        setAudioRoute(route)
    }

    /** The current audio state as the picker's map, for a fresh screen that
     *  has not seen an AUDIO_STATE event yet. */
    fun currentAudioState(): Map<String, Any?>? {
        val state = callAudioState ?: return null
        val mask = state.supportedRouteMask
        return mapOf(
            "route" to routeName(state.route),
            "speaker" to (state.route == CallAudioState.ROUTE_SPEAKER),
            "muted" to state.isMuted,
            "hasBluetooth" to (mask and CallAudioState.ROUTE_BLUETOOTH != 0),
            "hasWiredHeadset" to (mask and CallAudioState.ROUTE_WIRED_HEADSET != 0),
            "hasEarpiece" to (mask and CallAudioState.ROUTE_EARPIECE != 0),
            "bluetoothName" to bluetoothName(state),
        )
    }

    /**
     * What a DISCONNECTED event says about the call that ended, and why.
     *
     * The cause is what «تماس مجدد خودکار» is decided on, so it travels with
     * every DISCONNECTED — all three of them ([callCallback]'s state change,
     * [onCallRemoved], [republishCurrent]) build their payload here. Telecom's
     * codes are mapped to names Dart can switch on; [DisconnectCause.reason] is
     * the carrier's own text and goes along for the log only.
     *
     * `connectTimeMillis` is the other half of the decision: a call the far
     * end never picked up has none, and only such a call is redialled — a
     * conversation that ended is not a failed attempt, however short it was.
     */
    private fun disconnectPayload(call: Call): Map<String, Any?> {
        val cause = call.details?.disconnectCause
        return mapOf(
            "phone" to phoneOf(call),
            "direction" to directionOf(call),
            "cause" to causeName(cause?.code),
            "reason" to cause?.reason,
            "connectTimeMillis" to (call.details?.connectTimeMillis ?: 0L),
        )
    }

    private fun causeName(code: Int?): String = when (code) {
        DisconnectCause.BUSY -> "busy"
        DisconnectCause.REMOTE -> "remote"
        DisconnectCause.LOCAL -> "local"
        DisconnectCause.CANCELED -> "canceled"
        DisconnectCause.MISSED -> "missed"
        DisconnectCause.REJECTED -> "rejected"
        DisconnectCause.ERROR -> "error"
        DisconnectCause.RESTRICTED -> "restricted"
        DisconnectCause.OTHER -> "other"
        DisconnectCause.ANSWERED_ELSEWHERE -> "answered_elsewhere"
        DisconnectCause.CALL_PULLED -> "call_pulled"
        else -> "unknown"
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
            // When the call connected, per telecom (0 = not yet). The call
            // timer is derived from this rather than counted in Dart: the call
            // screen can now be left and come back, and a screen-local counter
            // restarted at zero every time — as it also did on a cold start
            // into a call that was already minutes old.
            "connectTimeMillis" to (call.details?.connectTimeMillis ?: 0L),
            // RINGING only: whether Flutter opens the full incoming screen, or
            // leaves the call to the heads-up card. See [incomingScreenCall].
            "showScreen" to (state != Call.STATE_RINGING || incomingScreenCall === call),
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
        val payload = data + mapOf("event" to event.name)
        if (event == CallEvent.DISCONNECTED) {
            // Never swallowed, and it clears the memo so the *next* call from
            // the same person is not mistaken for a repeat of this one.
            stickyState = null
            lastStatePayload = null
            // With its cause — see [disconnectPayload].
            CallEventStreamHandler.sendEvent(event, data + disconnectPayload(call))
            return
        }
        stickyState = payload
        // Same de-duplication as publishCallsChanged: onDetailsChanged fires
        // repeatedly during a merge with nothing the UI can see changed.
        if (payload == lastStatePayload) return
        lastStatePayload = payload
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
     * The subscription a call is on, or [SimRegistry.INVALID_SUBSCRIPTION_ID].
     *
     * Telecom names a `PhoneAccountHandle`, never a subscription, so this is
     * the same mapping the published call state and the call log use.
     */
    private fun subscriptionOf(call: Call): Int =
        SimRegistry.subscriptionIdForAccountId(this, call.details?.accountHandle?.id)
            ?: SimRegistry.INVALID_SUBSCRIPTION_ID

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
    private fun postIncomingCallNotification(
        phone: String,
        headsUp: Boolean = true,
        subscriptionId: Int = SimRegistry.INVALID_SUBSCRIPTION_ID,
    ) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = if (headsUp) CHANNEL_ID else SILENT_CHANNEL_ID
        ensureChannels(applicationContext)
        if (!areCallNotificationsEnabled(applicationContext)) {
            // Loud in the log because it is silent everywhere else: the card is
            // dropped and the full-screen intent with it. DefaultAppGate asks
            // the user to turn this back on.
            Log.e(TAG, "Call notifications are DISABLED — incoming call has no UI")
        }

        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_INCOMING_CALL, phone)
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
            .setSmallIcon(R.drawable.ic_stat_call)
            .setContentTitle(name)
            // «تماس ورودی · سیم ۲ · ایرانسل». On a locked phone this card is
            // often the only thing the user sees of the call, so the card the
            // call is ringing on has to be on it too — not only on the app's
            // own call screen behind the keyguard.
            .setContentText(
                if (SimRegistry.isMultiSim(applicationContext)) {
                    SimRegistry.labelOf(applicationContext, subscriptionId)
                        ?.let { "تماس ورودی · $it" } ?: "تماس ورودی"
                } else {
                    // One card: naming it says nothing, exactly as everywhere
                    // else in the app (see SimService.isMultiSim).
                    "تماس ورودی"
                },
            )
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

    // ── Ongoing-call notification («تماس در جریان») ──────────────────────────

    /**
     * Posts or cancels the ongoing-call card, from the one rule that decides
     * it: **a connected call the user cannot currently see needs a way back.**
     *
     * This is what makes leaving the call screen safe. The app holds the dialer
     * role, so it is the only call UI on the device: without a card in the
     * shade, minimizing the call — or simply pressing Home — left a live call
     * with no route back to it short of hanging up from the shade's own volume
     * dialog. On Android 12+ a `CallStyle` notification is also what produces
     * the green status-bar chip, which is the affordance the user actually
     * reaches for.
     *
     * Ringing is deliberately excluded: the incoming card already owns that
     * state, with its own پاسخ/رد buttons, and two cards for one call is what
     * the missed-call work was about.
     */
    fun refreshOngoingNotification() {
        val call = topLevelCalls().firstOrNull {
            it.state == Call.STATE_ACTIVE ||
                it.state == Call.STATE_HOLDING ||
                it.state == Call.STATE_DIALING ||
                it.state == Call.STATE_CONNECTING
        }
        if (call == null || callScreenShowing()) {
            cancelOngoingCallNotification()
            return
        }
        postOngoingCallNotification(call)
    }

    private fun postOngoingCallNotification(call: Call) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannels(applicationContext)
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

        // The tap target: bring the activity forward AND tell Dart to put the
        // call route back. Bringing the activity up alone would land the user
        // on whatever they minimized the call to look at.
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_RETURN_TO_CALL, true)
        } ?: Intent()
        val open = PendingIntent.getActivity(this, 3, launch, piFlags)
        val hangUp = PendingIntent.getBroadcast(
            this, 4,
            Intent(CallActionReceiver.ACTION_DECLINE).setPackage(packageName),
            piFlags,
        )

        val phone = phoneOf(call)
        val name = lookupContactName(phone)
            ?: phone.takeIf { it.isNotEmpty() }
            ?: "تماس"
        val caller = Person.Builder().setName(name).setImportant(true).build()
        val connectedAt = call.details?.connectTimeMillis ?: 0L
        val builder = NotificationCompat.Builder(this, ONGOING_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_call)
            .setContentTitle(name)
            .setContentText("تماس در جریان")
            .setStyle(NotificationCompat.CallStyle.forOngoingCall(caller, hangUp))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(open)
            // A CallStyle notification that is neither tied to a foreground
            // service nor carrying a full-screen intent is REJECTED with
            // IllegalArgumentException (see postIncomingCallNotification). This
            // service is bound, not foreground, so the intent is set — and
            // never fires, because the channel is IMPORTANCE_LOW.
            .setFullScreenIntent(open, false)
        // The live duration, ticked by the system. Only once telecom has a
        // connect time: before that the chronometer would count from the epoch.
        if (connectedAt > 0) {
            builder.setUsesChronometer(true).setWhen(connectedAt).setShowWhen(true)
        } else {
            builder.setShowWhen(false)
        }
        try {
            nm.notify(ONGOING_NOTIF_ID, builder.build())
        } catch (e: Exception) {
            // Never take the process down over a notification: this service IS
            // the call UI, and a crash here hands the call to the OEM dialer.
            Log.e(TAG, "ongoing-call notification rejected: ${e.message}")
        }
    }

    private fun cancelOngoingCallNotification() {
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(ONGOING_NOTIF_ID)
        } catch (e: Exception) {
            Log.d(TAG, "cancelOngoingCallNotification: ${e.message}")
        }
    }

    /**
     * «تماس بی‌پاسخ» — with «تماس» and «پیامک» actions, like Google Phone.
     *
     * Three things here were wrong and each was visible:
     *
     * - **One notification per caller**, not one per event. The id was the
     *   timestamp, so three missed calls from the same person left three
     *   identical cards in the shade with no way to tell them apart.
     * - **Actions.** Tapping only opened the app, which is not what anyone
     *   wants from a missed call — «تماس» dials straight back and «پیامک»
     *   opens the conversation.
     * - **A second card from somebody else.** The platform posts its own
     *   missed-call notification unless the default dialer declares it will do
     *   the job — that is [MissedCallNotificationReceiver], and it is why this
     *   method no longer ends by telling telecom anything (see the note at the
     *   bottom of it).
     */
    private fun postMissedCallNotification(phone: String, subscriptionId: Int) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannels(applicationContext)
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

        // Stable per caller, so a repeat call updates the card instead of
        // adding another. An unknown number ("") still gets its own slot.
        val notifId = MISSED_ID_BASE + (phone.hashCode() and 0xFFFF)
        val count = missedCounts.merge(phone, 1, Int::plus) ?: 1

        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        } ?: Intent()
        val contentIntent = PendingIntent.getActivity(this, notifId, launch, piFlags)

        val callBack = PendingIntent.getBroadcast(
            this, notifId + 1,
            Intent(CallActionReceiver.ACTION_CALL_BACK)
                .setPackage(packageName)
                .putExtra(CallActionReceiver.EXTRA_PHONE, phone)
                .putExtra(CallActionReceiver.EXTRA_NOTIF_ID, notifId)
                .putExtra(CallActionReceiver.EXTRA_SUBSCRIPTION_ID, subscriptionId),
            piFlags,
        )
        // «پیامک» goes through the launcher intent with a threadId extra — the
        // same deep link an SMS notification uses, so it lands in the same
        // conversation the app would open for that number.
        val smsIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("threadId", BlockedNumbers.normalizeToThreadId(phone))
        } ?: Intent()
        val message = PendingIntent.getActivity(
            this, notifId + 2, smsIntent, piFlags,
        )

        // Resolved once: this is a contacts-provider query, and it was being
        // run twice per missed call (for the title and again for the avatar).
        val contactName = lookupContactName(phone)
        val name = contactName ?: phone
        val title = if (count > 1) {
            "$count تماس بی‌پاسخ"
        } else {
            "تماس بی‌پاسخ"
        }
        val builder = NotificationCompat.Builder(this, MISSED_CHANNEL_ID)
            // Two icons, and they say different things. The SMALL one is the
            // handset silhouette the system tints into the status bar and
            // badges onto the card — that is what tells «تماس بی‌پاسخ» apart
            // from «پیامک» at a glance. The LARGE one is *who*: the caller's
            // photo, or the app's letter avatar when they have none. Without a
            // large icon most OEM shades fall back to the launcher icon, which
            // is how a missed call and a message ended up looking identical
            // next to each other on the tester's lock screen.
            .setSmallIcon(R.drawable.ic_stat_call)
            .setLargeIcon(
                lookupContactPhoto(phone)
                    ?: com.example.communication_super_app.NotificationAvatars
                        .letterAvatar(
                            contactName,
                            BlockedNumbers.normalizeToThreadId(phone),
                        ),
            )
            .setContentTitle(title)
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
        if (phone.isNotEmpty()) {
            builder.addAction(0, "تماس", callBack)
            builder.addAction(0, "پیامک", message)
        }
        nm.notify(notifId, builder.build())

        markMissedCall(applicationContext, phone)
        // NOTE: `cancelSystemMissedCallNotification()` is deliberately NOT
        // called here any more, and putting it back deletes this notification.
        //
        // It used to belong here: it told telecom "the default dialer has taken
        // the missed-call duty over", so telecom dropped its own card. Since
        // `MissedCallNotificationReceiver` exists telecom already knows that —
        // it hands the duty over *before* posting anything — and the same call
        // now means something else entirely. `cancelMissedCallsNotification()`
        // reaches `MissedCallNotifierImpl.clearMissedCalls`, which, for a
        // dialer that manages its own notifications, answers by broadcasting
        // `SHOW_MISSED_CALLS_NOTIFICATION` back with `EXTRA_NOTIFICATION_COUNT
        // = 0` — "there are no missed calls left, take your card down". Our
        // receiver obeyed, one line after we posted it, and the app's own
        // «تماس بی‌پاسخ» never appeared at all.
    }

    /** The caller's photo thumbnail, for the missed-call card's large icon. */
    private fun lookupContactPhoto(phone: String): android.graphics.Bitmap? {
        if (phone.isEmpty()) return null
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phone),
            )
            val photoUri = contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.PHOTO_THUMBNAIL_URI),
                null, null, null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null } ?: return null
            contentResolver.openInputStream(Uri.parse(photoUri))?.use {
                android.graphics.BitmapFactory.decodeStream(it)
            }
        } catch (e: Exception) {
            null
        }
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

/** Answers/declines the ringing call, and calls back a missed one. */
class CallActionReceiver : android.content.BroadcastReceiver() {
    companion object {
        const val ACTION_ANSWER = "com.example.communication_super_app.ANSWER_CALL"
        const val ACTION_DECLINE = "com.example.communication_super_app.DECLINE_CALL"

        /** «تماس» on a missed-call notification. */
        const val ACTION_CALL_BACK = "com.example.communication_super_app.CALL_BACK"
        const val EXTRA_PHONE = "phone"
        const val EXTRA_NOTIF_ID = "notifId"
        const val EXTRA_SUBSCRIPTION_ID = "subscriptionId"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_CALL_BACK) {
            callBack(context, intent)
            return
        }
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

    /**
     * Dials the number of a missed call straight from the shade.
     *
     * `TelecomManager.placeCall` rather than an `ACTION_CALL` intent, for the
     * same reason `CallHandler.makeCall` uses it: this app is the dialer, so an
     * intent would resolve back into its own process. The activity is brought
     * forward so the in-call screen is what the user lands on.
     */
    private fun callBack(context: Context, intent: Intent) {
        val phone = intent.getStringExtra(EXTRA_PHONE).orEmpty()
        val notifId = intent.getIntExtra(EXTRA_NOTIF_ID, -1)
        if (notifId >= 0) {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(notifId)
        }
        if (phone.isEmpty()) return
        try {
            val uri = Uri.fromParts("tel", phone, null)
            val subscriptionId = intent.getIntExtra(EXTRA_SUBSCRIPTION_ID, -1)
            // Call back on the card that took the call, when we know which.
            val account = SimRegistry.phoneAccountFor(context, subscriptionId)
            val extras = android.os.Bundle().apply {
                if (account != null) {
                    putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account)
                }
            }
            val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.placeCall(uri, extras)
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                }
                ?.let { context.startActivity(it) }
        } catch (e: SecurityException) {
            Log.e("CallActionReceiver", "call back refused: ${e.message}")
        } catch (e: Exception) {
            Log.e("CallActionReceiver", "call back failed: ${e.message}")
        }
    }
}
