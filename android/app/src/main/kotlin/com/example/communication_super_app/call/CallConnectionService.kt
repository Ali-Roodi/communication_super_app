package com.example.communication_super_app.call

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

class CallConnectionService : ConnectionService() {

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val connection = CallConnection()
        connection.setDialing()
        connection.address = request.address

        val phone = request.address?.schemeSpecificPart ?: ""
        CallEventStreamHandler.sendEvent(
            CallEvent.RINGING,
            mapOf("phone" to phone, "direction" to "outgoing")
        )
        return connection
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val connection = CallConnection()
        connection.setRinging()
        connection.address = request.address

        val phone = request.extras
            ?.getString(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS) ?: ""
        CallEventStreamHandler.sendEvent(
            CallEvent.INCOMING,
            mapOf("phone" to phone, "direction" to "incoming")
        )
        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ) {
        CallEventStreamHandler.sendEvent(CallEvent.CALL_FAILED)
    }
}
