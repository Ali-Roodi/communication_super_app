package com.example.communication_super_app.call

import android.telecom.Connection
import android.telecom.DisconnectCause

class CallConnection : Connection() {

    companion object {
        /** آخرین Connection فعال — توسط CallHandler برای end/answer/reject استفاده می‌شود */
        var instance: CallConnection? = null
    }

    init {
        instance = this
        audioModeIsVoip = false
        connectionCapabilities = CAPABILITY_HOLD or
                CAPABILITY_SUPPORT_HOLD or
                CAPABILITY_MUTE
    }

    override fun onAnswer() {
        setActive()
        CallEventStreamHandler.sendEvent(CallEvent.ACTIVE)
    }

    override fun onReject() {
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
        instance = null
        CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED)
    }

    override fun onDisconnect() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        instance = null
        CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED)
    }

    override fun onHold() {
        setOnHold()
        CallEventStreamHandler.sendEvent(CallEvent.ON_HOLD)
    }

    override fun onUnhold() {
        setActive()
        CallEventStreamHandler.sendEvent(CallEvent.ACTIVE)
    }

    /** Flutter side صفحه incoming call را نشان می‌دهد — نیازی به UI بومی نیست */
    override fun onShowIncomingCallUi() {
        // handled by Flutter
    }
}
