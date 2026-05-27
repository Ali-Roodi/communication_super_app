package com.example.communication_super_app.call

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class CallHandler(
    private val context: Context,
    flutterEngine: FlutterEngine
) {
    companion object {
        const val METHOD_CHANNEL = "com.example.communication_super_app/call"
        const val EVENT_CHANNEL  = "com.example.communication_super_app/call_events"
        private const val TAG    = "CallHandler"
    }

    private val audioManager by lazy {
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
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
                    "isInCall"        -> result.success(CallConnection.instance != null)
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

    private fun makeCall(phone: String, result: MethodChannel.Result) {
        val clean = phone.replace(Regex("[^+0-9]"), "")
        if (clean.isEmpty()) {
            result.error("INVALID_NUMBER", "شماره تلفن معتبر نیست", null)
            return
        }
        // Option A: hand off to the system default dialer via ACTION_CALL.
        // The native in-call screen manages the entire call lifecycle.
        // PHASE-2: switch to self-managed PhoneAccount for VoIP/custom UI.
        val uri = Uri.fromParts("tel", clean, null)
        val intent = Intent(Intent.ACTION_CALL, uri).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        result.success(null)
    }

    private fun endCall() {
        // PHASE-2 VoIP only — native cellular calls are managed by the system dialer
        CallConnection.instance?.onDisconnect()
    }

    private fun answerCall() = CallConnection.instance?.onAnswer()

    private fun rejectCall() = CallConnection.instance?.onReject()

    private fun holdCall(hold: Boolean) {
        if (hold) CallConnection.instance?.onHold()
        else      CallConnection.instance?.onUnhold()
    }

    private fun muteCall(muted: Boolean) {
        audioManager.isMicrophoneMute = muted
    }

    private fun setSpeakerphone(on: Boolean) {
        audioManager.isSpeakerphoneOn = on
        audioManager.mode = if (on) AudioManager.MODE_NORMAL else AudioManager.MODE_IN_CALL
    }

    private fun sendDtmf(digit: String) {
        if (digit.isEmpty()) return
        // Map the character to a ToneGenerator DTMF constant
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
            // Play local DTMF audio feedback (120 ms)
            // PHASE-2: also route the signal to the remote party via telecom stack
            val toneGen = ToneGenerator(AudioManager.STREAM_DTMF, 100)
            toneGen.startTone(toneType, 120)
        } catch (e: Exception) {
            Log.e(TAG, "DTMF tone error: ${e.message}")
        }
    }
}
