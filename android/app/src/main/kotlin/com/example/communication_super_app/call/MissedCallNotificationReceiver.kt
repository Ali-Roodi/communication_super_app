package com.example.communication_super_app.call

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telecom.TelecomManager
import android.util.Log

/**
 * Stops the **second** missed-call notification — the one from «Call
 * Management» / the OEM dialer that appeared next to this app's own.
 *
 * This receiver's mere existence is the fix, and that is not a trick: it is the
 * platform's documented handshake. Telecom's `MissedCallNotifierImpl` asks
 * `PackageManager.queryBroadcastReceivers` whether the **default dialer**
 * declares a receiver for [TelecomManager.ACTION_SHOW_MISSED_CALLS_NOTIFICATION]
 * (`shouldManageNotificationThroughDefaultDialer`). If one exists, telecom sends
 * this broadcast and posts **nothing itself**; if none does, it decides the
 * dialer cannot be trusted with the duty and posts its own card. This app held
 * ROLE_DIALER and posted a perfectly good «تماس بی‌پاسخ» notification of its own
 * from [CallInCallService.postMissedCallNotification] — while never declaring
 * the receiver — so the user got both, one of them in English.
 *
 * [CallInCallService.cancelSystemMissedCallNotification] was the previous
 * attempt at this and stays, because it does a second, different job: it marks
 * the missed calls read in the call log, which is what makes an *OEM* dialer
 * (Samsung's, verified on the SM A336E) drop its own duplicate. But it is a
 * race by construction — it cancels a card telecom may not have posted yet —
 * and it cannot stop telecom from posting one at all. This can.
 *
 * ### Why this handler posts nothing
 *
 * The notification is already posted, by `CallInCallService.onCallRemoved`,
 * which telecom binds for every call whether or not this app's UI is up. Posting
 * again here would double the card for one missed call, and worse: the id is
 * stable per caller and the *count* is incremented per post, so the second one
 * would relabel a single missed call «۲ تماس بی‌پاسخ». The broadcast is
 * therefore consumed and used only for the two things it can say that
 * `onCallRemoved` cannot:
 *
 *  * `EXTRA_CLEAR_MISSED_CALLS_INTENT` — telecom's own "these have been seen"
 *    intent, fired when the app clears its missed-call cards, so the platform's
 *    unread-missed-call count (the launcher badge, the call log's own flag) is
 *    cleared with them;
 *  * `EXTRA_NOTIFICATION_COUNT == 0` — a *refresh* saying there are no missed
 *    calls left (another app read them), which is the cue to take this app's
 *    cards down.
 *
 * Registered with `exported="true"` because the sender is the system, and
 * telecom sends it with the `READ_PHONE_STATE` receiver permission, which this
 * app holds.
 */
class MissedCallNotificationReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "MissedCallNotifier"

        /**
         * Telecom's "mark the missed calls seen" intent, kept from the last
         * broadcast so clearing our own cards can clear the platform's count
         * too. Volatile rather than persisted: it is a `PendingIntent` owned by
         * a running telecom, meaningless across a reboot, and a stale one is
         * simply refused.
         */
        @Volatile
        private var clearIntent: PendingIntent? = null

        /**
         * `TelecomManager.EXTRA_CLEAR_MISSED_CALLS_INTENT` — a real, stable
         * extra of this broadcast, but `@hide`, so it is not on the compile
         * classpath and has to be written out. The name has not changed since
         * the extra was introduced with the broadcast itself (API 23), and a
         * value that ever did change would simply leave [clearIntent] null,
         * which every use of it already tolerates.
         */
        private const val EXTRA_CLEAR_MISSED_CALLS_INTENT =
            "android.telecom.extra.CLEAR_MISSED_CALLS_INTENT"

        /**
         * Fires telecom's clear-missed-calls intent, if one has been handed
         * over. Safe to call at any time.
         */
        fun clearPlatformMissedCalls() {
            val intent = clearIntent ?: return
            clearIntent = null
            try {
                intent.send()
            } catch (e: PendingIntent.CanceledException) {
                Log.d(TAG, "clear-missed-calls intent had been cancelled")
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelecomManager.ACTION_SHOW_MISSED_CALLS_NOTIFICATION) return

        @Suppress("DEPRECATION")
        val pending = intent.getParcelableExtra<PendingIntent>(
            EXTRA_CLEAR_MISSED_CALLS_INTENT,
        )
        if (pending != null) clearIntent = pending

        // -1 means "the broadcast did not say", which telecom uses for the
        // refresh it sends on boot; 0 is an explicit "there are none left".
        val count = intent.getIntExtra(TelecomManager.EXTRA_NOTIFICATION_COUNT, -1)
        Log.d(TAG, "telecom handed the missed-call notification over (count=$count)")
        if (count == 0) {
            // Cancels THIS app's cards only — deliberately not
            // `clearMissedCallNotifications`, which would call
            // `TelecomManager.cancelMissedCallsNotification()` and so provoke
            // the very broadcast being handled here, round and round.
            CallInCallService.cancelMissedCallCards(context.applicationContext)
        }
        // Otherwise: nothing. CallInCallService.onCallRemoved posts the card,
        // with the caller's name, «تماس» and «پیامک». See the class doc.
    }
}
