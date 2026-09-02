package com.example.communication_super_app.sim

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
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
    // and the call log records the handle's *id string*. There is no public
    // API mapping the two, so the mapping is rebuilt by matching a handle's id
    // against everything telephony is known to put there.

    /**
     * The call-capable phone account that belongs to [subscriptionId].
     *
     * The handle id is `String.valueOf(subId)` on modern AOSP and the SIM's
     * ICC ID on older/OEM builds; the label is matched last because two SIMs
     * from the same carrier share it. Null means "let telecom pick" — which is
     * the correct behaviour, not an error.
     */
    @SuppressLint("MissingPermission")
    fun phoneAccountFor(context: Context, subscriptionId: Int): PhoneAccountHandle? {
        if (subscriptionId == INVALID_SUBSCRIPTION_ID) return null
        return try {
            val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return null
            val handles = telecom.callCapablePhoneAccounts
            if (handles.isEmpty()) return null

            val info = subscriptions(context)
                .firstOrNull { it.subscriptionId == subscriptionId } ?: return null

            handles.firstOrNull { it.id == subscriptionId.toString() }
                ?: handles.firstOrNull { matchesIccId(context, it, subscriptionId) }
                ?: handles.firstOrNull { handle ->
                    val label = telecom.getPhoneAccount(handle)?.label?.toString()
                    !label.isNullOrBlank() &&
                        (label == info.displayName || label == info.carrierName)
                }
                // Last resort: telecom hands the accounts back in slot order on
                // every build we have seen, so index == slot is a better guess
                // than dropping the user's choice on the floor.
                ?: handles.getOrNull(info.slotIndex)
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
        !iccId.isNullOrBlank() && (handle.id == iccId || handle.id.startsWith(iccId))
    } catch (e: Exception) {
        false
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

        accountId.toIntOrNull()?.let { asSubId ->
            if (subs.any { it.subscriptionId == asSubId }) return asSubId
        }
        return try {
            val manager = subscriptionManager(context) ?: return null
            manager.activeSubscriptionInfoList
                ?.firstOrNull {
                    val iccId = runCatching { it.iccId }.getOrNull()
                    !iccId.isNullOrBlank() && (accountId == iccId || accountId.startsWith(iccId))
                }
                ?.subscriptionId
        } catch (e: Exception) {
            null
        }
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
