package com.example.communication_super_app.scheduled

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires when a scheduled message is due.
 *
 * When the Flutter engine is alive the delivery is handed to Dart
 * ([ScheduledSmsChannel]) so the BLoCs see the send and the chat re-renders;
 * Dart re-arms the alarm itself once it is done. Otherwise the message is sent
 * natively off the main thread (via [BroadcastReceiver.goAsync]) and the alarm
 * is re-armed for the next pending message.
 */
class ScheduledSmsAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val pending = goAsync()

        val handedToDart = ScheduledSmsChannel.requestDartDelivery(
            onFallback = { Thread { deliverNatively(app) }.start() },
        )
        if (handedToDart) {
            pending.finish()
            return
        }

        Thread {
            try {
                deliverNatively(app)
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun deliverNatively(app: Context) {
        ScheduledSmsWorker.processDue(app)
        ScheduledSmsScheduler.reschedule(app)
    }
}
