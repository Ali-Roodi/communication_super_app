package com.example.communication_super_app.scheduled

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires when a scheduled message is due. Sends the due messages off the main
 * thread (via [BroadcastReceiver.goAsync]) and then re-arms the alarm for the
 * next pending message.
 */
class ScheduledSmsAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val pending = goAsync()
        Thread {
            try {
                ScheduledSmsWorker.processDue(app)
                ScheduledSmsScheduler.reschedule(app)
            } finally {
                pending.finish()
            }
        }.start()
    }
}
