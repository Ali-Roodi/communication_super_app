package com.example.communication_super_app.call

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object CallEventStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun sendEvent(event: CallEvent, data: Map<String, Any?> = emptyMap()) {
        Handler(Looper.getMainLooper()).post {
            val payload = data.toMutableMap()
            payload["event"] = event.name
            eventSink?.success(payload)
        }
    }
}
