package com.example.communication_super_app.call

import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.telephony.PhoneNumberUtils
import android.util.Log
import com.example.communication_super_app.sim.SimRegistry
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class CallHandler(
    private val context: Context,
    flutterEngine: FlutterEngine,
    private val activity: Activity? = null,
) {
    companion object {
        const val METHOD_CHANNEL = "com.example.communication_super_app/call"
        const val EVENT_CHANNEL  = "com.example.communication_super_app/call_events"
        private const val TAG    = "CallHandler"

        /** Longest a held key may transmit before the watchdog releases it. */
        private const val DTMF_MAX_MS = 5_000L

        /** startActivityForResult code for the default-dialer role request. */
        const val REQUEST_DEFAULT_DIALER_ROLE = 9003
    }

    private val audioManager by lazy {
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    /** Pending result of an in-flight default-dialer-role request. */
    private var pendingRoleResult: MethodChannel.Result? = null

    // Single reusable DTMF tone generator — created lazily, reused across
    // presses so rapid dialing does not leak a ToneGenerator each time.
    private val dtmfToneGenerator: ToneGenerator? by lazy {
        try {
            ToneGenerator(AudioManager.STREAM_DTMF, 80)
        } catch (e: Exception) {
            Log.e(TAG, "ToneGenerator init error: ${e.message}")
            null
        }
    }

    init {
        // ── Method Channel ─────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "makeCall"        -> makeCall(
                        call.argument<String>("phone") ?: "",
                        call.argument<Int>("subscriptionId") ?: -1,
                        result,
                    )
                    "endCall"         -> { endCall(); result.success(null) }
                    "answerCall"      -> { answerCall(); result.success(null) }
                    "rejectCall"      -> { rejectCall(); result.success(null) }
                    "holdCall"        -> {
                        holdCall(call.argument<Boolean>("hold") ?: true)
                        result.success(null)
                    }
                    "muteCall"        -> {
                        muteCall(call.argument<Boolean>("muted") ?: false)
                        result.success(null)
                    }
                    "setSpeakerphone" -> {
                        setSpeakerphone(call.argument<Boolean>("on") ?: false)
                        result.success(null)
                    }
                    // Explicit output selection — the only way to reach a
                    // bluetooth headset, which is neither "speaker on" nor
                    // "speaker off".
                    "setAudioRoute"   -> {
                        CallInCallService.instance?.setAudioRouteByName(
                            call.argument<String>("route") ?: "earpiece",
                        )
                        result.success(null)
                    }
                    "getAudioState"   -> result.success(
                        CallInCallService.instance?.currentAudioState(),
                    )
                    // A held key: the tone goes down the line from touch-down
                    // to release, the way Google Phone's in-call pad sends it.
                    "startDtmf"       -> {
                        startDtmf(call.argument<String>("digit") ?: "")
                        result.success(null)
                    }
                    "stopDtmf"        -> {
                        stopDtmf()
                        result.success(null)
                    }
                    "playKeypadTone"  -> {
                        playLocalTone(call.argument<String>("digit") ?: "")
                        result.success(null)
                    }
                    "mergeCalls"      -> {
                        CallInCallService.instance?.mergeCalls()
                        result.success(null)
                    }
                    "swapCalls"       -> {
                        CallInCallService.instance?.swapCalls()
                        result.success(null)
                    }
                    // Whether the Flutter in-call route is on screen. Drives
                    // the ongoing-call card, which is the only way back to a
                    // call the user minimized — no lifecycle callback fires
                    // when the call screen is left for another screen of the
                    // same app, so Dart has to say so.
                    "setCallScreenVisible" -> {
                        CallInCallService.setCallScreenVisible(
                            call.argument<Boolean>("visible") ?: false,
                        )
                        result.success(null)
                    }
                    "canMerge"        -> result.success(CallInCallService.canMerge())
                    "isInCall"        -> result.success(
                        CallInCallService.currentCall != null || CallConnection.instance != null
                    )
                    "isDefaultDialer" -> result.success(isDefaultDialer())
                    "requestDefaultDialerRole" -> requestDefaultDialerRole(result)
                    "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
                    "areCallNotificationsEnabled" -> result.success(
                        CallInCallService.areCallNotificationsEnabled(context),
                    )
                    "openFullScreenIntentSettings" -> {
                        openFullScreenIntentSettings()
                        result.success(true)
                    }
                    "getVoicemailNumber" -> result.success(
                        voicemailNumber(call.argument<Int>("subscriptionId") ?: -1),
                    )
                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(true)
                    }
                    "openSoundSettings" -> {
                        openSoundSettings()
                        result.success(true)
                    }
                    // «مسدود کردن تماس‌های ناشناس». Mirrored into a native
                    // preference file because the rule is applied inside
                    // `CallInCallService.onCallAdded`, which routinely runs
                    // with no Flutter engine at all. See [CallPrefs].
                    "setBlockUnknownCallers" -> {
                        CallPrefs.setBlockUnknownCallers(
                            context,
                            call.argument<Boolean>("value") ?: false,
                        )
                        result.success(true)
                    }
                    "getBlockUnknownCallers" -> result.success(
                        CallPrefs.blockUnknownCallers(context),
                    )
                    else              -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Security exception: ${e.message}")
                result.error("PERMISSION_DENIED", e.message, null)
            } catch (e: Exception) {
                Log.e(TAG, "Error: ${e.message}")
                result.error("CALL_ERROR", e.message, null)
            }
        }

        // ── Event Channel ──────────────────────────────────────────────
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(CallEventStreamHandler)
    }

    // ── Default dialer role ──────────────────────────────────────────────

    /** True when this app currently holds the default-dialer role. */
    fun isDefaultDialer(): Boolean {
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        return tm?.defaultDialerPackage == context.packageName
    }

    /**
     * The SIM's voicemail number, so long-pressing «۱» dials it the way every
     * stock dialer does. Null when the carrier never provisioned one (common on
     * Iranian SIMs) or READ_PHONE_STATE was refused — the caller then tells the
     * user instead of dialing something wrong.
     */
    private fun voicemailNumber(subscriptionId: Int): String? = try {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE)
            as? android.telephony.TelephonyManager
        // Per SIM, not per phone: the two cards are two carriers and two
        // mailboxes, and reading the default subscription's number would dial
        // the wrong one — the same mistake `isInService` made before dual-SIM.
        val forSub = if (subscriptionId >= 0) {
            try {
                tm?.createForSubscriptionId(subscriptionId)
            } catch (e: Exception) {
                Log.w(TAG, "voicemail: no TelephonyManager for sub $subscriptionId")
                tm
            }
        } else {
            tm
        }
        forSub?.voiceMailNumber?.takeIf { it.isNotBlank() }
    } catch (e: SecurityException) {
        Log.w(TAG, "voicemail number denied: ${e.message}")
        null
    }

    /**
     * Opens this app's notification settings — the system screen Google
     * Messages links to from «اعلان‌ها».
     */
    /**
     * The system "Sound & vibration" screen.
     *
     * The ringtone and the vibrate-on-ring behaviour are Telecom's, not this
     * app's — it holds the dialer role but never plays the ringer — so
     * «آهنگ زنگ و لرزش تماس» sends the user where the setting actually lives.
     * A device without that screen (rare, but it is an optional activity) falls
     * back to the top-level settings rather than throwing.
     */
    private fun openSoundSettings() {
        val host = activity ?: context
        val flags = if (activity == null) Intent.FLAG_ACTIVITY_NEW_TASK else 0
        // Tried, not probed: `resolveActivity` is filtered by targetSdk-30
        // package visibility and can answer null for a screen that is plainly
        // there.
        try {
            host.startActivity(
                Intent(android.provider.Settings.ACTION_SOUND_SETTINGS).addFlags(flags),
            )
        } catch (e: android.content.ActivityNotFoundException) {
            Log.w(TAG, "No sound settings screen: ${e.message}")
            host.startActivity(
                Intent(android.provider.Settings.ACTION_SETTINGS).addFlags(flags),
            )
        }
    }

    private fun openNotificationSettings() {
        val intent = Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
            .apply { if (activity == null) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        (activity ?: context).startActivity(intent)
    }

    /**
     * Whether the app may launch its call screen from a notification.
     *
     * From Android 14 `USE_FULL_SCREEN_INTENT` is only auto-granted to apps
     * whose core function was calling/alarms **at install time**. An app that
     * takes the dialer role later — which is exactly this one — is denied, the
     * notification is flagged FSI_REQUESTED_BUT_DENIED, and an incoming call on
     * a locked phone falls back to the OEM dialer's UI.
     */
    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val nm = context.getSystemService(android.app.NotificationManager::class.java)
        return nm?.canUseFullScreenIntent() ?: true
    }

    /** Opens the per-app screen where the user grants the above. */
    private fun openFullScreenIntentSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        val intent = Intent(
            android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
            Uri.parse("package:${context.packageName}"),
        ).apply { if (activity == null) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        try {
            (activity ?: context).startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "full-screen-intent settings unavailable: ${e.message}")
            openNotificationSettings()
        }
    }

    /**
     * Launches the system "set default phone app" dialog. Outcome resolved in
     * [handleRoleActivityResult] (forwarded from MainActivity.onActivityResult).
     */
    private fun requestDefaultDialerRole(result: MethodChannel.Result) {
        if (isDefaultDialer()) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }
        val intent: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = context.getSystemService(RoleManager::class.java)
            if (roleManager?.isRoleAvailable(RoleManager.ROLE_DIALER) == true) {
                roleManager.createRequestRoleIntent(RoleManager.ROLE_DIALER)
            } else null
        } else {
            Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER).apply {
                putExtra(
                    TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME,
                    context.packageName,
                )
            }
        }
        if (intent == null) {
            result.error("ROLE_UNAVAILABLE", "Dialer role not available on this device", null)
            return
        }
        pendingRoleResult?.success(false)
        pendingRoleResult = result
        try {
            act.startActivityForResult(intent, REQUEST_DEFAULT_DIALER_ROLE)
        } catch (e: Exception) {
            pendingRoleResult = null
            result.error("ROLE_REQUEST_FAILED", e.message, null)
        }
    }

    /** Called from MainActivity.onActivityResult. Returns true when consumed. */
    fun handleRoleActivityResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_DEFAULT_DIALER_ROLE) return false
        // The role state is the source of truth, not the resultCode (OEM
        // dialogs are inconsistent).
        pendingRoleResult?.success(isDefaultDialer())
        pendingRoleResult = null
        return true
    }

    // ── Call actions ─────────────────────────────────────────────────────
    // Prefer the telecom Call bound through CallInCallService (cellular calls
    // while this app is the default dialer); fall back to the legacy
    // CallConnection (self-managed VoIP path).

    private fun makeCall(phone: String, subscriptionId: Int, result: MethodChannel.Result) {
        // PhoneNumberUtils.stripSeparators, NOT a hand-rolled `[^+0-9]` strip.
        // The platform's own rule keeps every character that is actually
        // dialable — `*` `#` (USSD/MMI: «*100#», «*140*11#», call forwarding),
        // `,` `;` (post-dial pause/wait for IVR extensions stored in contacts)
        // and `N` — and it folds Persian/Arabic-Indic digits to ASCII on the
        // way (Character.digit), which the regex did not. The old strip is why
        // no USSD code could ever be dialed: «*100#» reached telecom as «100».
        val clean = PhoneNumberUtils.stripSeparators(phone) ?: ""
        if (clean.isEmpty()) {
            result.error("INVALID_NUMBER", "شماره تلفن معتبر نیست", null)
            return
        }
        // fromParts takes the DECODED ssp, so the `#` is percent-escaped for us
        // (`tel:*100%23`) and telecom hands telephony back the literal «*100#»
        // via getSchemeSpecificPart(). Uri.parse("tel:$clean") would truncate
        // at the `#` — it would read as a fragment.
        val uri = Uri.fromParts("tel", clean, null)

        // Which SIM to dial from. A null handle means "let telecom choose",
        // which is the right behaviour on a single-SIM phone and whenever the
        // user has a default voice SIM pinned — telecom then honours the system
        // setting instead of us second-guessing it. It also covers the case
        // where the requested subscription has no matching phone account (a
        // card removed between the picker and the tap).
        val account: PhoneAccountHandle? = SimRegistry.phoneAccountFor(context, subscriptionId)

        if (isDefaultDialer()) {
            // Default-dialer path: TelecomManager.placeCall is the direct API —
            // no UserCallActivity trampoline over this app. The trampoline made
            // Samsung's SCallUI fallback think no dialer UI was foreground
            // ("isTopActivity: false") and launch the OEM in-call screen on top.
            val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val extras = android.os.Bundle().apply {
                if (account != null) {
                    putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account)
                }
            }
            tm.placeCall(uri, extras)
        } else {
            // Not the default dialer: hand over to the system dialer app. An
            // MMI code survives this too — but only because [uri] escapes the
            // `#`; the usual "ACTION_CALL can't dial USSD" folklore is really
            // Uri.parse("tel:*100#") losing everything from the `#` onwards.
            val intent = Intent(Intent.ACTION_CALL, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (account != null) {
                    putExtra(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account)
                }
            }
            context.startActivity(intent)
        }
        result.success(null)
    }

    private fun endCall() {
        val call = CallInCallService.currentCall
        if (call != null) {
            call.disconnect()
            return
        }
        CallConnection.instance?.onDisconnect()
    }

    private fun answerCall() {
        val call = CallInCallService.currentCall
        if (call != null) {
            call.answer(VideoProfile.STATE_AUDIO_ONLY)
            return
        }
        CallConnection.instance?.onAnswer()
    }

    private fun rejectCall() {
        val call = CallInCallService.currentCall
        Log.d(TAG, "rejectCall: currentCall=${call != null} state=${call?.state}")
        if (call != null) {
            // reject() is only honored while RINGING — if the call slipped into
            // any other state (some OEMs move it during the tap), reject would
            // silently do nothing and the caller would keep ringing. Disconnect
            // covers every other state.
            if (call.state == android.telecom.Call.STATE_RINGING) {
                call.reject(false, null)
            } else {
                call.disconnect()
            }
            return
        }
        CallConnection.instance?.onReject()
    }

    private fun holdCall(hold: Boolean) {
        val call = CallInCallService.currentCall
        if (call != null) {
            if (hold) call.hold() else call.unhold()
            return
        }
        if (hold) CallConnection.instance?.onHold()
        else      CallConnection.instance?.onUnhold()
    }

    private fun muteCall(muted: Boolean) {
        val svc = CallInCallService.instance
        if (svc != null) {
            // InCallService.setMuted routes through telecom — the only way that
            // reliably mutes the uplink during a telecom-managed call.
            svc.setMicMuted(muted)
            return
        }
        audioManager.isMicrophoneMute = muted
    }

    private fun setSpeakerphone(on: Boolean) {
        val svc = CallInCallService.instance
        if (svc != null) {
            svc.setSpeaker(on)
            return
        }
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = on
        audioManager.mode = if (on) AudioManager.MODE_NORMAL else AudioManager.MODE_IN_CALL
    }

    /** The call a tone is being held on, so the release stops it on the same
     *  call even if the foreground call changed while the key was down. */
    private var dtmfCall: android.telecom.Call? = null

    private val dtmfHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /** A release that never arrives (the engine torn down mid-press) must not
     *  leave a tone going down the line for the rest of the call. */
    private val dtmfWatchdog = Runnable { stopDtmf() }

    /**
     * Starts transmitting [digit] to the far end — the in-call keypad (IVR
     * menus, the «امتیاز به اپراتور» survey at the end of a support call).
     *
     * The target is the call that is **ACTIVE** ([CallInCallService.dtmfTarget]),
     * not blindly `currentCall`. That field follows what the screen shows, and
     * around call waiting, a second leg or a leg that just dropped it can name
     * a ringing, held or already-disconnected call — telecom silently drops a
     * tone sent there, so the keypad looked alive while the IVR heard nothing.
     *
     * Held rather than fired: `playDtmfTone` immediately followed by
     * `stopDtmfTone` asks the network for a zero-length digit, and whether that
     * is stretched to something an IVR accepts is left to each modem.
     */
    private fun startDtmf(digit: String) {
        if (digit.isEmpty()) return
        stopDtmf() // one tone at a time — a second finger replaces the first
        val target = CallInCallService.dtmfTarget()
        if (target != null) {
            target.playDtmfTone(digit[0])
            dtmfCall = target
            dtmfHandler.postDelayed(dtmfWatchdog, DTMF_MAX_MS)
        } else {
            Log.w(TAG, "DTMF not sent: no active call")
        }
        // Local audible feedback either way.
        playLocalTone(digit)
    }

    private fun stopDtmf() {
        dtmfHandler.removeCallbacks(dtmfWatchdog)
        val call = dtmfCall ?: return
        dtmfCall = null
        try {
            call.stopDtmfTone()
        } catch (e: Exception) {
            Log.e(TAG, "stopDtmfTone error: ${e.message}")
        }
    }

    /**
     * Audible keypress feedback with nothing sent down the line — the dialer
     * keypad's tone.
     *
     * It is a separate entry point on purpose: [startDtmf] transmits whenever a
     * call exists, and the keypad opened from «افزودن تماس» sits on top of a
     * live one, so sharing the method played the number being dialled into the
     * ear of the person already on the call.
     */
    private fun playLocalTone(digit: String) {
        if (digit.isEmpty()) return
        val toneType = when (digit[0]) {
            '0'  -> ToneGenerator.TONE_DTMF_0
            '1'  -> ToneGenerator.TONE_DTMF_1
            '2'  -> ToneGenerator.TONE_DTMF_2
            '3'  -> ToneGenerator.TONE_DTMF_3
            '4'  -> ToneGenerator.TONE_DTMF_4
            '5'  -> ToneGenerator.TONE_DTMF_5
            '6'  -> ToneGenerator.TONE_DTMF_6
            '7'  -> ToneGenerator.TONE_DTMF_7
            '8'  -> ToneGenerator.TONE_DTMF_8
            '9'  -> ToneGenerator.TONE_DTMF_9
            '*'  -> ToneGenerator.TONE_DTMF_S
            '#'  -> ToneGenerator.TONE_DTMF_P
            else -> return
        }
        try {
            dtmfToneGenerator?.startTone(toneType, 120)
        } catch (e: Exception) {
            Log.e(TAG, "DTMF tone error: ${e.message}")
        }
    }
}
