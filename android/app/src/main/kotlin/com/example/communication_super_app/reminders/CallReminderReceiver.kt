package com.example.communication_super_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** The reminder alarm, and «۱۰ دقیقه بعد» on a reminder's card. */
class CallReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val pending = goAsync()
        Thread {
            try {
                when (intent.action) {
                    CallReminders.ACTION_ALARM -> CallReminders.fireDue(app)
                    CallReminders.ACTION_SNOOZE -> CallReminders.snooze(
                        app,
                        number = intent.getStringExtra(CallReminders.EXTRA_NUMBER).orEmpty(),
                        kind = intent.getStringExtra(CallReminders.EXTRA_KIND)
                            ?: CallReminders.KIND_CALL,
                        name = intent.getStringExtra(CallReminders.EXTRA_NAME),
                        notifId = intent.getIntExtra(CallReminders.EXTRA_NOTIF_ID, 0),
                    )
                }
            } finally {
                pending.finish()
            }
        }.start()
    }
}
