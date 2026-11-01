package com.example.communication_super_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.telephony.PhoneNumberUtils
import android.telephony.TelephonyManager
import android.util.Log
import com.example.communication_super_app.NumberListRules.Channel
import com.example.communication_super_app.NumberListRules.Config
import com.example.communication_super_app.NumberListRules.Mode
import com.example.communication_super_app.hidden.HiddenNumbers

/**
 * The device half of «فهرست سیاه و سفید» ([NumberListRules]): its native
 * mirror and the one question every send, receive and call path asks.
 *
 * The lists are applied in the SMS receivers, in `SmsHandler.sendSms`, in the
 * scheduled worker, the shade's reply, respond-via-message and the in-call
 * service — paths that run with no Flutter engine as often as not, so the
 * configuration lives in a preference file this app owns. `SettingsBloc`
 * writes it on load and on every change, as one set.
 */
object NumberLists {
    private const val TAG = "NumberLists"
    private const val FILE = "number_lists"
    private const val KEY_MODE_PREFIX = "mode_"
    private const val KEY_BLACK = "black"
    private const val KEY_WHITE = "white"
    private const val KEY_CONTACTS_ALLOWED = "contacts_allowed"

    fun config(context: Context): Config = try {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        Config(
            modes = Channel.values().associateWith {
                Mode.of(prefs.getString(KEY_MODE_PREFIX + it.key, null))
            },
            black = entries(prefs.getStringSet(KEY_BLACK, null)),
            white = entries(prefs.getStringSet(KEY_WHITE, null)),
            contactsAllowed = prefs.getBoolean(KEY_CONTACTS_ALLOWED, false),
        )
    } catch (e: Exception) {
        Config()
    }

    fun setConfig(context: Context, config: Config) {
        try {
            val edit = context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            for (channel in Channel.values()) {
                edit.putString(KEY_MODE_PREFIX + channel.key, config.modeOf(channel).key)
            }
            // Copies: a set handed to putStringSet must not be mutated
            // afterwards, and Android never copies it.
            edit.putStringSet(KEY_BLACK, HashSet(config.black))
                .putStringSet(KEY_WHITE, HashSet(config.white))
                .putBoolean(KEY_CONTACTS_ALLOWED, config.contactsAllowed)
                .apply()
        } catch (e: Exception) {
            // Stays at its previous value; failing the settings page over it
            // would be worse.
        }
    }

    /**
     * Whether [phone] may use [channel]. An outgoing call to an emergency
     * number is always allowed, and a decision that cannot be made (a
     * preference or provider error) allows: nothing here may cost the user a
     * message or a call because something unrelated broke.
     */
    fun allows(context: Context, phone: String, channel: Channel): Boolean = try {
        if (channel == Channel.CALL_OUT && isEmergency(context, phone)) {
            true
        } else {
            NumberListRules.allows(
                phone,
                channel,
                config(context),
                isHidden = { HiddenNumbers.isHidden(context, phone) },
                isContact = { isContact(context, phone) },
            )
        }
    } catch (e: Exception) {
        Log.w(TAG, "List check failed: ${e.javaClass.simpleName}")
        true
    }

    /** Re-normalised on the way in, so nothing malformed is ever matched. */
    private fun entries(stored: Set<String>?): List<String> =
        stored.orEmpty().mapNotNull { NumberListRules.normalizePattern(it) }.distinct()

    private fun isContact(context: Context, phone: String): Boolean? {
        if (context.checkSelfPermission(Manifest.permission.READ_CONTACTS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        return try {
            context.contentResolver.query(
                Uri.withAppendedPath(
                    ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(phone),
                ),
                arrayOf(ContactsContract.PhoneLookup._ID),
                null, null, null,
            )?.use { it.moveToFirst() }
        } catch (e: Exception) {
            Log.w(TAG, "Contact lookup failed: ${e.javaClass.simpleName}")
            null
        }
    }

    private fun isEmergency(context: Context, phone: String): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            context.getSystemService(TelephonyManager::class.java)
                ?.isEmergencyNumber(phone) == true
        } else {
            @Suppress("DEPRECATION")
            PhoneNumberUtils.isEmergencyNumber(phone)
        }
    } catch (e: Exception) {
        // No telephony to ask. The short-number rule still lets 110/112/115
        // through.
        false
    }
}
