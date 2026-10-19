package com.example.communication_super_app.sim

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Log

/**
 * The one place that answers "which SIMs does this phone have".
 *
 * It is an `object`, not a handler, because everything that needs a SIM answer
 * runs in a different process state: the Flutter method channel (app alive),
 * `SmsNotifier` / `IncomingSmsReceiver` (cold start, no engine), and
 * `ScheduledSmsWorker` (app dead). A handler bound to the engine could not
 * serve those, and each of them re-querying `SubscriptionManager` by hand is
 * how the labels drift apart between the shade and the chat.
 *
 * Every read is defensive: `SubscriptionManager` throws `SecurityException`
 * until READ_PHONE_STATE is granted, and the whole app must degrade to
 * "single SIM, unknown" rather than crash — an SMS that arrives before the
 * permission dialog is answered still has to be delivered.
 */
object SimRegistry {
    private const val TAG = "SimRegistry"

    /** `subscriptionId` value meaning "no particular SIM / use the default". */
    const val INVALID_SUBSCRIPTION_ID = -1

    /**
     * One active SIM. [slotIndex] is the physical slot (0-based) — it is what
     * the UI shows as «سیم ۱»/«سیم ۲», because a subscription id is an opaque
     * per-device number that changes when a SIM is re-inserted.
     */
    data class SimInfo(
        val subscriptionId: Int,
        val slotIndex: Int,
        val displayName: String,
        val carrierName: String,
        val number: String,
        val color: Int?,
        val isEmbedded: Boolean,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "subscriptionId" to subscriptionId,
            "slotIndex" to slotIndex,
            "displayName" to displayName,
            "carrierName" to carrierName,
            "number" to number,
            "color" to color,
            "isEmbedded" to isEmbedded,
        )
    }

    private fun subscriptionManager(context: Context): SubscriptionManager? =
        context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager

    // ── Cache ────────────────────────────────────────────────────────────
    // Reading the roster is several binder round-trips (and, from API 33, one
    // more per SIM for the card's own number). It is on paths that must not
    // dawdle: every incoming-SMS notification asks twice, and every telecom
    // call-state change asks once. The roster changes only when a card is
    // inserted, removed or renamed, so it is cached with a short TTL — long
    // enough to collapse the burst around one event, short enough that a SIM
    // swap is picked up without anyone having to invalidate by hand.

    private const val CACHE_TTL_MS = 30_000L

    @Volatile
    private var cached: List<SimInfo>? = null

    @Volatile
    private var cachedAt = 0L

    /** Drops the cache — call after anything that can change the roster. */
    @JvmStatic
    fun invalidate() {
        cached = null
    }

    /**
     * Active subscriptions, ordered by physical slot.
     *
     * Empty on a permission refusal or an airplane-moded/SIM-less device —
     * callers treat empty as "single, unknown SIM" and never as an error.
     *
     * [withNumbers] fetches each card's own number, which is an extra binder
     * call per SIM and is only ever *displayed* (the Dart picker). Native
     * callers want a label, so they leave it off.
     */
    @SuppressLint("MissingPermission")
    fun subscriptions(context: Context, withNumbers: Boolean = false): List<SimInfo> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) return emptyList()

        if (!withNumbers) {
            val snapshot = cached
            if (snapshot != null &&
                android.os.SystemClock.elapsedRealtime() - cachedAt < CACHE_TTL_MS
            ) {
                return snapshot
            }
        }

        return try {
            val manager = subscriptionManager(context) ?: return emptyList()
            val active: List<SubscriptionInfo> =
                manager.activeSubscriptionInfoList ?: return emptyList()
            active
                .sortedBy { it.simSlotIndex }
                .map { info ->
                    SimInfo(
                        subscriptionId = info.subscriptionId,
                        slotIndex = info.simSlotIndex,
                        displayName = info.displayName?.toString().orEmpty(),
                        carrierName = info.carrierName?.toString().orEmpty(),
                        number = if (withNumbers) {
                            phoneNumber(context, manager, info)
                        } else {
                            ""
                        },
                        color = runCatching { info.iconTint }.getOrNull(),
                        isEmbedded = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                            runCatching { info.isEmbedded }.getOrDefault(false),
                    )
                }
                .also {
                    // Only the cheap (number-less) shape is cached; the Dart
                    // read must never be served a roster with blank numbers.
                    if (!withNumbers) {
                        cached = it
                        cachedAt = android.os.SystemClock.elapsedRealtime()
                    }
                }
        } catch (e: SecurityException) {
            Log.w(TAG, "subscriptions denied: ${e.message}")
            emptyList()
        } catch (e: Exception) {
            Log.e(TAG, "subscriptions failed: ${e.message}", e)
            emptyList()
        }
    }

    /**
     * The SIM's own number, which most carriers never write to the card — an
     * empty string is the normal case, not a failure, and the UI falls back to
     * the carrier name.
     *
     * On API 33+ `SubscriptionInfo.getNumber()` is gated behind
     * READ_PHONE_NUMBERS and returns "" instead of throwing, so the newer
     * `SubscriptionManager.getPhoneNumber` is tried first.
     */
    @SuppressLint("MissingPermission")
    private fun phoneNumber(
        context: Context,
        manager: SubscriptionManager,
        info: SubscriptionInfo,
    ): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching { manager.getPhoneNumber(info.subscriptionId) }
                .getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?.let { return it }
        }
        @Suppress("DEPRECATION")
        return runCatching { info.number }.getOrNull().orEmpty()
    }

    /** Whether more than one SIM is active — the switch every SIM affordance hangs off. */
    fun isMultiSim(context: Context): Boolean = subscriptions(context).size > 1

    /** Physical slot of [subscriptionId], or null when it is not an active SIM. */
    fun slotOf(context: Context, subscriptionId: Int): Int? =
        subscriptions(context).firstOrNull { it.subscriptionId == subscriptionId }?.slotIndex

    /**
     * Short label for a subscription — «سیم ۱ · ایرانسل» reduced to what fits a
     * notification subtext or a bubble caption. Null when the id is unknown, so
     * the caller can omit the badge instead of printing "SIM -1".
     */
    fun labelOf(context: Context, subscriptionId: Int): String? {
        if (subscriptionId == INVALID_SUBSCRIPTION_ID) return null
        val info = subscriptions(context)
            .firstOrNull { it.subscriptionId == subscriptionId } ?: return null
        val name = info.displayName.ifBlank { info.carrierName }
        val slot = "سیم ${persianDigits(info.slotIndex + 1)}"
        return if (name.isBlank()) slot else "$slot · $name"
    }

    private fun persianDigits(value: Int): String {
        val digits = charArrayOf('۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹')
        return value.toString().map { c ->
            if (c in '0'..'9') digits[c - '0'] else c
        }.joinToString("")
    }

    // ── Defaults ─────────────────────────────────────────────────────────
    // The system-wide "which SIM does this by default" settings. Google
    // Messages/Phone only show a SIM picker when the user has NOT pinned a
    // default; once they have, the picker is replaced by a silent choice.

    @SuppressLint("MissingPermission")
    fun defaultSmsSubscriptionId(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            runCatching { SmsManager.getDefaultSmsSubscriptionId() }
                .getOrDefault(INVALID_SUBSCRIPTION_ID)
        } else {
            INVALID_SUBSCRIPTION_ID
        }

    fun defaultVoiceSubscriptionId(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            runCatching { SubscriptionManager.getDefaultVoiceSubscriptionId() }
                .getOrDefault(INVALID_SUBSCRIPTION_ID)
        } else {
            INVALID_SUBSCRIPTION_ID
        }

    fun defaultDataSubscriptionId(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            runCatching { SubscriptionManager.getDefaultDataSubscriptionId() }
                .getOrDefault(INVALID_SUBSCRIPTION_ID)
        } else {
            INVALID_SUBSCRIPTION_ID
        }

    // ── Telecom bridge ───────────────────────────────────────────────────
    // Calls are placed against a PhoneAccountHandle, not a subscription id,
    // and the call log records the handle's *id string*. Telephony answers
    // the mapping itself ([subscriptionOfHandle]); the id/ICC/label guesses
    // below it are only for the builds where it cannot.

    /**
     * The subscription behind [handle], as telephony itself answers it, or
     * null for a handle that is not a SIM (a VoIP account) or a build that
     * cannot say.
     *
     * This is the authoritative mapping and it comes first. The guesses after
     * it are not safe on every phone: the handle id is the subscription id
     * only on newer AOSP (older and OEM builds use the ICC ID, which an app
     * may not read since Android 10), and two cards from the same carrier —
     * two Irancell or two MCI lines, the common case here — carry the same
     * label, so a label match handed SIM 1's calls to whichever account was
     * listed first. A call meant for one line went out on the other.
     */
    @SuppressLint("MissingPermission")
    private fun subscriptionOfHandle(context: Context, handle: PhoneAccountHandle): Int? {
        val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return null
        val id: Int? = try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                    telephony.getSubscriptionId(handle)
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ->
                    // createForPhoneAccountHandle is public from API 26 but the
                    // instance getSubscriptionId() only from 30; before that it
                    // is a hidden method, so it is reached reflectively and a
                    // build that refuses simply falls through to the guesses.
                    telephony.createForPhoneAccountHandle(handle)?.let { scoped ->
                        TelephonyManager::class.java
                            .getMethod("getSubscriptionId")
                            .invoke(scoped) as? Int
                    }
                else -> null
            }
        } catch (e: Exception) {
            null
        }
        return id?.takeIf { it != INVALID_SUBSCRIPTION_ID }
    }

    /**
     * The call-capable phone account that belongs to [subscriptionId].
     *
     * Telephony's own answer first ([subscriptionOfHandle]). Without one, the
     * handle id is `String.valueOf(subId)` on modern AOSP and the SIM's ICC ID
     * on older/OEM builds, and a label only counts when exactly one account
     * carries it. Null means "let telecom pick" — which is the correct
     * behaviour, not an error.
     */
    @SuppressLint("MissingPermission")
    fun phoneAccountFor(context: Context, subscriptionId: Int): PhoneAccountHandle? {
        if (subscriptionId == INVALID_SUBSCRIPTION_ID) return null
        return try {
            val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return null
            val handles = telecom.callCapablePhoneAccounts
            if (handles.isEmpty()) return null

            val subs = subscriptions(context)
            val info = subs.firstOrNull { it.subscriptionId == subscriptionId } ?: return null

            val answered = handles.associateWith { subscriptionOfHandle(context, it) }
            answered.entries.firstOrNull { it.value == subscriptionId }?.let { return it.key }
            // Telephony named a card for every account and none is this one:
            // it is not callable right now. Guessing could only pick the other.
            if (answered.values.none { it == null }) return null

            handles.firstOrNull { it.id == subscriptionId.toString() }
                ?: handles.firstOrNull { matchesIccId(context, it, subscriptionId) }
                ?: handles.filter { handle ->
                    val label = telecom.getPhoneAccount(handle)?.label?.toString()
                    !label.isNullOrBlank() &&
                        (label == info.displayName || label == info.carrierName)
                }.singleOrNull()
                // Last resort: telecom hands the accounts back in slot order on
                // every build we have seen. Only when there is one account per
                // card — any other list has no order to trust.
                ?: handles.takeIf { it.size == subs.size }?.getOrNull(info.slotIndex)
        } catch (e: SecurityException) {
            Log.w(TAG, "phoneAccountFor denied: ${e.message}")
            null
        } catch (e: Exception) {
            Log.e(TAG, "phoneAccountFor failed: ${e.message}", e)
            null
        }
    }

    /**
     * The inverse of [phoneAccountFor]: which SIM a stored `PhoneAccountHandle`
     * belongs to, or null when it belongs to none of the cards in the phone now.
     *
     * Null is the important answer. A contact's «سیم‌کارت تماس» is written into
     * the address book and outlives the SIM: the card can be pulled, swapped or
     * re-provisioned with a new subscription id. Resolving through the *live*
     * roster means a preference pointing at a card that is gone reads as "no
     * preference" and the call falls back to the normal rules, instead of being
     * placed on whatever now sits in that slot.
     */
    fun subscriptionFor(context: Context, handle: PhoneAccountHandle): Int? {
        return try {
            subscriptions(context)
                .map { it.subscriptionId }
                .firstOrNull { phoneAccountFor(context, it) == handle }
        } catch (e: Exception) {
            Log.e(TAG, "subscriptionFor failed: ${e.message}", e)
            null
        }
    }

    @SuppressLint("MissingPermission")
    private fun matchesIccId(
        context: Context,
        handle: PhoneAccountHandle,
        subscriptionId: Int,
    ): Boolean = try {
        val manager = subscriptionManager(context)
        val iccId = manager?.activeSubscriptionInfoList
            ?.firstOrNull { it.subscriptionId == subscriptionId }
            ?.let { runCatching { it.iccId }.getOrNull() }
        iccMatches(handle.id, iccId)
    } catch (e: Exception) {
        false
    }

    /**
     * Whether an account id and an ICC ID name the same card. Builds whose
     * account id is the ICC ID do not agree on its spelling: some keep the
     * trailing `F` padding of an odd-length ICC ID, some drop it, some
     * upper-case the hex and some do not — and an exact comparison then
     * misses every call, which is a SIM badge that never appears.
     */
    internal fun iccMatches(accountId: String?, iccId: String?): Boolean {
        if (accountId.isNullOrBlank() || iccId.isNullOrBlank()) return false
        val a = accountId.trim().uppercase().trimEnd('F')
        val b = iccId.trim().uppercase().trimEnd('F')
        if (a.isEmpty() || b.isEmpty()) return false
        if (a == b) return true
        // A prefix only counts when both are long enough to be ICC IDs (18–20
        // digits): a short id that happens to start the same is not a card.
        return a.length >= 18 && b.length >= 18 && (a.startsWith(b) || b.startsWith(a))
    }

    /**
     * Inverse of [phoneAccountFor]: the subscription behind a call-log row's
     * `PHONE_ACCOUNT_ID`. Returns null for a non-telephony account (a VoIP app's
     * calls are in the same log) so the caller shows no SIM badge rather than a
     * wrong one.
     */
    @SuppressLint("MissingPermission")
    fun subscriptionIdForAccountId(context: Context, accountId: String?): Int? {
        if (accountId.isNullOrBlank()) return null
        val subs = subscriptions(context)
        if (subs.isEmpty()) return null

        // The live account with this id, asked of telephony — the same
        // authoritative answer [phoneAccountFor] starts with, so a call is
        // stamped with the card it was placed on.
        callCapableAccounts(context)
            .firstOrNull { (handle, _) -> handle.id == accountId }
            ?.let { (handle, _) -> subscriptionOfHandle(context, handle) }
            ?.takeIf { sub -> subs.any { it.subscriptionId == sub } }
            ?.let { return it }

        accountId.toIntOrNull()?.let { asSubId ->
            if (subs.any { it.subscriptionId == asSubId }) return asSubId
        }
        return try {
            val manager = subscriptionManager(context) ?: return null
            manager.activeSubscriptionInfoList
                ?.firstOrNull { iccMatches(accountId, runCatching { it.iccId }.getOrNull()) }
                ?.subscriptionId
        } catch (e: Exception) {
            null
        }
    }

    /**
     * The SIM behind a telecom account — of a live call, or rebuilt from a
     * call-log row's component and id.
     *
     * Telephony is asked about the *whole* handle first. That is what was
     * missing: the call screen and the call log only ever looked the account
     * up by its id string, which is the subscription id on some builds and
     * the ICC ID (or something else again) on others — so on those phones a
     * call on SIM 2 carried no SIM at all. Telephony knows its own accounts
     * whatever their ids look like.
     */
    fun subscriptionOfAccount(context: Context, handle: PhoneAccountHandle?): Int? {
        if (handle == null) return null
        val subs = subscriptions(context)
        if (subs.isEmpty()) return null
        subscriptionOfHandle(context, handle)
            ?.takeIf { sub -> subs.any { it.subscriptionId == sub } }
            ?.let { return it }
        return subscriptionIdForAccountId(context, handle.id)
    }

    /** [subscriptionOfAccount] for a call-log row's `PHONE_ACCOUNT_*` pair. */
    fun subscriptionOfAccount(context: Context, component: String?, accountId: String?): Int? {
        if (accountId.isNullOrBlank()) return null
        val name = component?.let { ComponentName.unflattenFromString(it) }
            ?: return subscriptionIdForAccountId(context, accountId)
        return subscriptionOfAccount(context, PhoneAccountHandle(name, accountId))
    }

    /**
     * The account telecom itself places an ordinary call on — the phone's own
     * «default SIM for calls» — or null when the user chose «ask every time»
     * (or it names a card that is not callable now).
     *
     * This, and not `SubscriptionManager`'s default voice subscription, is
     * the setting telecom routes by: some builds keep the two apart, and a
     * call placed by the app on the subscription default then left on a
     * different card from the one the phone's settings show.
     */
    @SuppressLint("MissingPermission")
    fun defaultVoiceAccount(context: Context): PhoneAccountHandle? = try {
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        val selected = telecom?.userSelectedOutgoingPhoneAccount
        selected?.takeIf { it in telecom.callCapablePhoneAccounts }
    } catch (e: Exception) {
        Log.w(TAG, "default voice account unreadable: ${e.javaClass.simpleName}")
        null
    }

    /** The SIM of [defaultVoiceAccount], for showing it; -1 when there is none. */
    fun defaultVoiceSubscriptionId(context: Context): Int =
        subscriptionOfAccount(context, defaultVoiceAccount(context)) ?: INVALID_SUBSCRIPTION_ID

    /**
     * The calling account the contact holding [number] is pinned to
     * («سیم‌کارت تماس», `Phone.PREFERRED_PHONE_ACCOUNT_*`, Android 10+), when
     * it is a card this phone can call on now; null otherwise.
     *
     * The handle is returned as stored, not re-derived from a subscription:
     * it is exactly what telecom needs, and a round trip through the
     * subscription would add a mapping that can only go wrong.
     */
    @SuppressLint("MissingPermission")
    fun contactCallAccount(context: Context, number: String): PhoneAccountHandle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || number.isBlank()) return null
        return try {
            val resolver = context.contentResolver
            val lookup = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(number),
            )
            val contactId = resolver.query(
                lookup,
                arrayOf(ContactsContract.PhoneLookup._ID),
                null,
                null,
                null,
            )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null } ?: return null
            val handle = resolver.query(
                ContactsContract.Data.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.PREFERRED_PHONE_ACCOUNT_COMPONENT_NAME,
                    ContactsContract.CommonDataKinds.Phone.PREFERRED_PHONE_ACCOUNT_ID,
                ),
                "${ContactsContract.Data.CONTACT_ID} = ? AND ${ContactsContract.Data.MIMETYPE} = ? AND " +
                    "${ContactsContract.CommonDataKinds.Phone.PREFERRED_PHONE_ACCOUNT_COMPONENT_NAME} IS NOT NULL",
                arrayOf(contactId.toString(), ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE),
                null,
            )?.use { c ->
                if (!c.moveToFirst()) return@use null
                val component = c.getString(0)?.let { ComponentName.unflattenFromString(it) }
                val id = c.getString(1)
                if (component == null || id.isNullOrEmpty()) null else PhoneAccountHandle(component, id)
            } ?: return null
            val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            handle.takeIf { telecom?.callCapablePhoneAccounts?.contains(it) == true }
        } catch (e: Exception) {
            // No contacts permission, or a provider that refuses: no preference.
            null
        }
    }

    // ── The app's own default card (Settings → «سیم‌کارت‌ها») ──────────────
    // Mirrored from `SimService.setAppDefault`. Absent / -1 = follow the
    // phone; -2 = calls ask every time; anything else is a subscription id,
    // honoured only while that card is in the phone.

    private const val PREFS = "sim_prefs"
    private const val KEY_VOICE = "app_default_voice"
    private const val KEY_SMS = "app_default_sms"
    const val APP_FOLLOW_PHONE = -1
    const val APP_ASK = -2

    fun setAppDefaults(context: Context, voice: Int, sms: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt(KEY_VOICE, voice)
            .putInt(KEY_SMS, sms)
            .apply()
    }

    private fun appDefault(context: Context, key: String): Int =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(key, APP_FOLLOW_PHONE)

    private fun active(context: Context, subscriptionId: Int): Boolean =
        subscriptionId >= 0 && subscriptions(context).any { it.subscriptionId == subscriptionId }

    /**
     * The card an SMS goes out on when its conversation has none of its own:
     * the app's default, else the phone's (-1 = let the platform pick).
     */
    fun defaultSmsFor(context: Context): Int {
        val app = appDefault(context, KEY_SMS)
        return if (active(context, app)) app else defaultSmsSubscriptionId()
    }

    /** How an ordinary dial of a number chooses its SIM — see [routeFor]. */
    enum class CallRoute { CONTACT, APP, PHONE_DEFAULT, ASK, SINGLE }

    /**
     * Where a call to [number] goes when nobody picked a card for this one
     * call: the contact's own card, else the app's default (Settings →
     * «سیم‌کارت‌ها»), else the phone's default, else the user is asked.
     * [CallRoute.SINGLE] when there is nothing to choose. The handle is what
     * to dial with; null for [CallRoute.PHONE_DEFAULT] on purpose — telecom
     * then uses its own default.
     */
    fun routeFor(context: Context, number: String): Pair<CallRoute, PhoneAccountHandle?> {
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        val accounts = try {
            @SuppressLint("MissingPermission")
            val list = telecom?.callCapablePhoneAccounts
            list ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
        if (accounts.size < 2) return CallRoute.SINGLE to null
        contactCallAccount(context, number)?.let { return CallRoute.CONTACT to it }
        when (val app = appDefault(context, KEY_VOICE)) {
            APP_ASK -> return CallRoute.ASK to null
            APP_FOLLOW_PHONE -> Unit
            else -> if (active(context, app)) {
                phoneAccountFor(context, app)?.let { return CallRoute.APP to it }
            }
        }
        defaultVoiceAccount(context)?.let { return CallRoute.PHONE_DEFAULT to it }
        return CallRoute.ASK to null
    }

    /** Every call-capable account paired with the subscription it belongs to. */
    @SuppressLint("MissingPermission")
    fun callCapableAccounts(context: Context): List<Pair<PhoneAccountHandle, PhoneAccount?>> = try {
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        telecom?.callCapablePhoneAccounts?.map { it to telecom.getPhoneAccount(it) } ?: emptyList()
    } catch (e: Exception) {
        emptyList()
    }
}
