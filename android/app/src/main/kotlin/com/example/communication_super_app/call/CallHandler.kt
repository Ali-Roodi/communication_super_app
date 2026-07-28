package com.example.communication_super_app.call

import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log
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
                    "makeCall"        -> makeCall(call.argument<String>("phone") ?: "", result)
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
                    "sendDtmf"        -> {
                        sendDtmf(call.argument<String>("digit") ?: "")
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
                    "canMerge"        -> result.success(CallInCallService.canMerge())
                    "isInCall"        -> result.success(
                        CallInCallService.currentCall != null || CallConnection.instance != null
                    )
                    "isDefaultDialer" -> result.success(isDefaultDialer())
                    "requestDefaultDialerRole" -> requestDefaultDialerRole(result)
                    "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
                    "openFullScreenIntentSettings" -> {
                        openFullScreenIntentSettings()
                        result.success(true)
                    }
                    "getVoicemailNumber" -> result.success(voicemailNumber())
                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(true)
                    }
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
    private fun voicemailNumber(): String? = try {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE)
            as? android.telephony.TelephonyManager
        tm?.voiceMailNumber?.takeIf { it.isNotBlank() }
    } catch (e: SecurityException) {
        Log.w(TAG, "voicemail number denied: ${e.message}")
        null
    }

    /**
     * Opens this app's notification settings — the system screen Google
     * Messages links to from «اعلان‌ها».
     */
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

    private fun makeCall(phone: String, result: MethodChannel.Result) {
        val clean = phone.replace(Regex("[^+0-9]"), "")
        if (clean.isEmpty()) {
            result.error("INVALID_NUMBER", "شماره تلفن معتبر نیست", null)
            return
        }
        val uri = Uri.fromParts("tel", clean, null)
        if (isDefaultDialer()) {
            // Default-dialer path: TelecomManager.placeCall is the direct API —
            // no UserCallActivity trampoline over this app. The trampoline made
            // Samsung's SCallUI fallback think no dialer UI was foreground
            // ("isTopActivity: false") and launch the OEM in-call screen on top.
            val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.placeCall(uri, android.os.Bundle())
        } else {
            // Not the default dialer: hand over to the system dialer app.
            val intent = Intent(Intent.ACTION_CALL, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
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

    private fun sendDtmf(digit: String) {
        if (digit.isEmpty()) return
        // Route the tone to the remote party through telecom when a real call
        // is up (this is what IVR menus hear)…
        CallInCallService.currentCall?.let { call ->
            call.playDtmfTone(digit[0])
            call.stopDtmfTone()
        }
        // …and always play local audible feedback.
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
