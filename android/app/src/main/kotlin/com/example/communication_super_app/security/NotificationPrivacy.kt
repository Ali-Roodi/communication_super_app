package com.example.communication_super_app.security

import android.app.NotificationManager
import android.content.Context
import android.os.Bundle
import android.util.Log
import com.example.communication_super_app.SmsNotifier
import com.example.communication_super_app.call.CallInCallService

/**
 * «پنهان کردن محتوای اعلان‌ها» — while the app is **locked** behind its PIN,
 * an SMS or missed-call notification says only that something arrived, never
 * who from or what it says: the same treatment «پیام رمز جدید» always had.
 * While the app is open (or inside its «قفل خودکار» window, where coming back
 * would not ask for the PIN either) the cards are the ordinary ones — see
 * [AppLockSession].
 *
 * The switch is read with no Flutter engine (the SMS receivers and the in-call
 * service post these cards from a cold process), so Dart mirrors one boolean
 * here — `PIN is set && the switch is on` — on every launch and on every change
 * (`NotificationPrivacySync` on the Dart side).
 *
 * Until Dart has written it once (the first launch after the update that
 * introduced it) the answer falls back to "is there an app PIN at all", read
 * from the presence of the PIN entry in `flutter_secure_storage`'s file. Only
 * the entry's *name* is looked at, never its value, and the fallback agrees
 * with the switch's default (on), so a protected app is never announced in
 * clear during that window.
 *
 * A card that names anybody carries [revealing] in its extras, so that
 * [privatizeActive] can find it again and fold it when the app locks.
 */
object NotificationPrivacy {
    private const val TAG = "NotificationPrivacy"
    private const val FILE = "app_lock_prefs"
    private const val KEY_HIDE = "hide_notification_content"

    /** `flutter_secure_storage` 9.x: file and key-name prefix it writes under. */
    private const val SECURE_STORAGE_FILE = "FlutterSecureStorage"
    private const val SECURE_STORAGE_PREFIX =
        "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"

    /** Mirrors `AppConstants.pinKey`. */
    private const val PIN_KEY = "app_pin"

    /** Extras key on a card that shows content: its kind, [KIND_SMS] or
     *  [KIND_MISSED_CALL]. */
    private const val EXTRA_REVEALS = "hamresan.reveals"

    /** Extras key: the count the card announces («۳ پیام جدید»). */
    private const val EXTRA_COUNT = "hamresan.reveals.count"

    const val KIND_SMS = "sms"
    const val KIND_MISSED_CALL = "missed_call"

    /** Whether a card posted now must hide its content. */
    fun hideContent(context: Context): Boolean =
        switchedOn(context) && !AppLockSession.isOpen()

    /** The switch: a PIN is set and «پنهان کردن محتوای اعلان‌ها» is on. */
    fun switchedOn(context: Context): Boolean = try {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        if (prefs.contains(KEY_HIDE)) {
            prefs.getBoolean(KEY_HIDE, true)
        } else {
            context.getSharedPreferences(SECURE_STORAGE_FILE, Context.MODE_PRIVATE)
                .contains("${SECURE_STORAGE_PREFIX}_$PIN_KEY")
        }
    } catch (e: Exception) {
        Log.w(TAG, "switch read failed: ${e.javaClass.simpleName}")
        // Failing towards privacy: a card that says too little is a nuisance,
        // one that says too much on a locked app is the bug this exists for.
        true
    }

    fun setHideContent(context: Context, value: Boolean) {
        try {
            context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_HIDE, value)
                .apply()
        } catch (e: Exception) {
            Log.w(TAG, "hideContent write failed: ${e.javaClass.simpleName}")
        }
    }

    /** The extras that mark a card as showing content (see [privatizeActive]). */
    fun revealing(kind: String, count: Int): Bundle = Bundle().apply {
        putString(EXTRA_REVEALS, kind)
        putInt(EXTRA_COUNT, count)
    }

    /**
     * The app has just locked: every card posted in full while it was open is
     * replaced, under its own tag and id, by the private card a locked app
     * would have posted — silently, since it is not news. Cards that already
     * say nothing (private ones, «پیام رمز جدید», the hidden phonebook's) carry
     * no [EXTRA_REVEALS] and are left alone.
     */
    fun privatizeActive(context: Context) {
        try {
            if (!switchedOn(context)) return
            val nm =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            var folded = 0
            for (sbn in nm.activeNotifications) {
                val card = sbn.notification ?: continue
                val extras = card.extras ?: continue
                val kind = extras.getString(EXTRA_REVEALS) ?: continue
                val count = extras.getInt(EXTRA_COUNT, 1).coerceAtLeast(1)
                val replacement = when (kind) {
                    KIND_SMS -> SmsNotifier.privateCard(
                        context, count, card.`when`, card.contentIntent, silent = true,
                    )
                    KIND_MISSED_CALL -> CallInCallService.privateMissedCard(
                        context, count, card.`when`, card.contentIntent, silent = true,
                    )
                    else -> continue
                }
                nm.notify(sbn.tag, sbn.id, replacement)
                folded++
            }
            if (folded > 0) Log.i(TAG, "folded $folded card(s)")
        } catch (e: Exception) {
            Log.w(TAG, "privatizeActive failed: ${e.javaClass.simpleName}")
        }
    }
}
