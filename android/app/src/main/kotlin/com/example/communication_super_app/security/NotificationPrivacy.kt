package com.example.communication_super_app.security

import android.content.Context
import android.util.Log

/**
 * «پنهان کردن محتوای اعلان‌ها» — while the app is protected by a PIN, an SMS or
 * missed-call notification says only that something arrived, never who from or
 * what it says: the same treatment «پیام رمز جدید» always had.
 *
 * Read with no Flutter engine (the SMS receivers and the in-call service post
 * these cards from a cold process), so Dart mirrors one boolean here —
 * `PIN is set && the switch is on` — on every launch and on every change
 * (`NotificationPrivacySync` on the Dart side).
 *
 * Until Dart has written it once (the first launch after the update that
 * introduced it) the answer falls back to "is there an app PIN at all", read
 * from the presence of the PIN entry in `flutter_secure_storage`'s file. Only
 * the entry's *name* is looked at, never its value, and the fallback agrees
 * with the switch's default (on), so a protected app is never announced in
 * clear during that window.
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

    fun hideContent(context: Context): Boolean = try {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        if (prefs.contains(KEY_HIDE)) {
            prefs.getBoolean(KEY_HIDE, true)
        } else {
            context.getSharedPreferences(SECURE_STORAGE_FILE, Context.MODE_PRIVATE)
                .contains("${SECURE_STORAGE_PREFIX}_$PIN_KEY")
        }
    } catch (e: Exception) {
        Log.w(TAG, "hideContent read failed: ${e.javaClass.simpleName}")
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
}
