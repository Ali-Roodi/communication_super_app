package com.example.communication_super_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * WAP_PUSH_DELIVER stub. Declaring this receiver is **required** for the app
 * to qualify for the default-SMS-app role (ROLE_SMS); the system checks that a
 * candidate handles all four components (SMS_DELIVER, WAP_PUSH_DELIVER,
 * SENDTO activity, RESPOND_VIA_MESSAGE service).
 *
 * The app intentionally does not support MMS — incoming MMS is acknowledged
 * and dropped.
 */
class MmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("MmsReceiver", "MMS received and ignored (MMS not supported)")
    }
}
