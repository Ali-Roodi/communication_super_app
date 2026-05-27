package com.example.communication_super_app.call

import android.content.Context
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.telecom.TelecomManager
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

    private val telecomManager by lazy {
        context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
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
        val uri = Uri.fromParts("tel", clean, null)
        telecomManager.placeCall(uri, Bundle())
        result.success(null)
    }

    private fun endCall() {
        CallConnection.instance?.onDisconnect() ?: run {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                @Suppress("DEPRECATION")
                telecomManager.endCall()
            }
        }
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
        if (digit.isNotEmpty()) CallConnection.instance?.playDtmfTone(digit[0])
    }
}
