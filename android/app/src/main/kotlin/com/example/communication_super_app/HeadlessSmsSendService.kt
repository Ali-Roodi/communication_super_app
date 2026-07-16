package com.example.communication_super_app

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.telephony.SmsManager
import android.util.Log

/**
 * Handles `ACTION_RESPOND_VIA_MESSAGE` — fired when the user rejects an
 * incoming call with a quick text reply. Declaring this service is required
 * for the default-SMS-app role; implementing it keeps "reject with message"
 * working while this app holds the role.
 */
class HeadlessSmsSendService : Service() {
    companion object {
        private const val TAG = "HeadlessSmsSend"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val text = intent?.getStringExtra(Intent.EXTRA_TEXT)
            val recipient = intent?.data?.schemeSpecificPart
            if (!text.isNullOrBlank() && !recipient.isNullOrBlank()) {
                @Suppress("DEPRECATION")
                val smsManager = SmsManager.getDefault()
                smsManager.sendTextMessage(recipient, null, text, null, null)
                Log.d(TAG, "Respond-via-message sent to $recipient")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Respond-via-message failed: ${e.message}", e)
        } finally {
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }
}
