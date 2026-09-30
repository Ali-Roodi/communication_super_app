package com.example.communication_super_app.call

import android.content.Context

/**
 * The handful of call settings that have to be readable **with the Flutter
 * engine dead**.
 *
 * `CallInCallService` decides whether to reject a call inside `onCallAdded`,
 * which routinely runs in a process that has no engine at all (the phone was
 * asleep, the app was never opened this boot). Dart's own `SharedPreferences`
 * store is reachable in principle, but its file name and key encoding are
 * implementation details of the plugin; mirroring the one value we need into a
 * file this app owns is a contract we control. `SettingsBloc` writes it on load
 * and on every change, so the mirror cannot drift for longer than one launch.
 */
object CallPrefs {
    private const val FILE = "call_prefs"
    private const val KEY_BLOCK_UNKNOWN = "block_unknown_callers"
    private const val KEY_PIN_TO_ANSWER = "pin_to_answer_calls"

    /**
     * «مسدود کردن تماس‌های ناشناس» — reject calls that arrive with no number:
     * a withheld/private caller id, a payphone, or a number telecom could not
     * present. Off by default, exactly as Google Phone's own «Unknown» switch
     * is: a blocked caller has no way to tell the user they were blocked.
     */
    fun blockUnknownCallers(context: Context): Boolean = try {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getBoolean(KEY_BLOCK_UNKNOWN, false)
    } catch (e: Exception) {
        false
    }

    fun setBlockUnknownCallers(context: Context, value: Boolean) {
        try {
            context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_BLOCK_UNKNOWN, value)
                .apply()
        } catch (e: Exception) {
            // A preference that cannot be written simply stays at its default;
            // failing a settings toggle over it would be worse.
        }
    }

    /**
     * «رمز برای پاسخ به تماس» — when on, «پاسخ» on the incoming-call card
     * opens the app's incoming screen (where the app lock is asked first)
     * instead of answering straight from the shade. Off by default: a ringing
     * phone must be answerable with one touch — while driving above all.
     */
    fun pinToAnswerCalls(context: Context): Boolean = try {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getBoolean(KEY_PIN_TO_ANSWER, false)
    } catch (e: Exception) {
        false
    }

    fun setPinToAnswerCalls(context: Context, value: Boolean) {
        try {
            context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_PIN_TO_ANSWER, value)
                .apply()
        } catch (e: Exception) {
            // Stays at its default, as above.
        }
    }
}
