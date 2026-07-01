package com.example.communication_super_app.scheduled

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arms the scheduled-SMS alarm after a device reboot or an app update, since
 * AlarmManager alarms do not survive either.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED ->
                ScheduledSmsScheduler.reschedule(context.applicationContext)
        }
    }
}
