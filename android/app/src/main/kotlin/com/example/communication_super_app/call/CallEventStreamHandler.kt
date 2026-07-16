package com.example.communication_super_app.call

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object CallEventStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Cold-start replay: an incoming call's fullScreenIntent may have
        // launched the app AFTER the INCOMING event fired. Re-deliver the
        // current call state so Flutter never misses the ringing call.
        CallInCallService.stickyState?.let { sticky ->
            Handler(Looper.getMainLooper()).post { eventSink?.success(sticky) }
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun sendEvent(event: CallEvent, data: Map<String, Any?> = emptyMap()) {
        val payload = data.toMutableMap()
        payload["event"] = event.name
        sendRaw(payload)
    }

    /** Sends an arbitrary payload (must carry an "event" key). */
    fun sendRaw(payload: Map<String, Any?>) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(payload)
        }
    }
}
