package com.example.communication_super_app.call

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log

class CallConnectionService : ConnectionService() {

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val connection = CallConnection()
        connection.setDialing()
        // address is read-only in Kotlin — use setAddress(uri, presentation)
        request.address?.let { uri ->
            connection.setAddress(uri, TelecomManager.PRESENTATION_ALLOWED)
        }

        val phone = request.address?.schemeSpecificPart ?: ""
        Log.d("CallConnectionService", "Outgoing call to: $phone")
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
        // address is read-only in Kotlin — use setAddress(uri, presentation)
        request.address?.let { uri ->
            connection.setAddress(uri, TelecomManager.PRESENTATION_ALLOWED)
        }

        val phone = request.extras
            ?.getString(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS) ?: ""
        Log.d("CallConnectionService", "Incoming call from: $phone")
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
