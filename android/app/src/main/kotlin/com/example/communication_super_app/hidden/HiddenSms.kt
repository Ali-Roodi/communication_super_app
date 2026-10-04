package com.example.communication_super_app.hidden

import android.content.Context
import com.example.communication_super_app.scheduled.ScheduledSmsWorker
import com.example.communication_super_app.smscrypto.SecureSmsInbox
import org.json.JSONObject

/**
 * An SMS from a hidden number, plain or encrypted (owner's decision,
 * 1405/07/06: a hidden contact's normal SMS are hidden too). It never enters
 * `content://sms` (`SmsDeliverReceiver` skips it) nor the `messages` table:
 * the whole message — sender included — is sealed into [SealedInbox], and the
 * only trace is the same bare «پیام رمز جدید» an encrypted SMS gets.
 */
object HiddenSms {
    /**
     * Takes the SMS if its sender is hidden. False means "not ours" — or that
     * it could not be sealed, in which case the caller carries on with the
     * normal path rather than lose the message.
     */
    fun receive(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        subscriptionId: Int,
    ): Boolean {
        // From a hidden contact, or an operator's notice naming one.
        val about = if (HiddenNumbers.isHidden(context, address)) {
            null
        } else {
            HiddenNumbers.mentionedBy(context, address, body) ?: return false
        }
        val record = JSONObject().apply {
            put("k", SealedInbox.KIND_SMS)
            put("address", address)
            put("body", body)
            put("timestamp", timestamp)
            put("subscriptionId", subscriptionId)
            if (about != null) put("about", about)
        }
        if (!SealedInbox.enqueue(context, SealedInbox.KIND_SMS, record)) return false
        // A handshake or a receipt from a hidden contact announces nothing,
        // exactly as from anyone else.
        if (!SecureSmsInbox.isEncrypted(body) || SecureSmsInbox.announces(body)) {
            SecureSmsInbox.notifyArrived(context)
        }
        return true
    }

    /** True when this SMS belongs to the hidden phonebook (sender or subject). */
    fun concerns(context: Context, address: String?, body: String?): Boolean =
        HiddenNumbers.isHidden(context, address) ||
            HiddenNumbers.mentionedBy(context, address, body) != null

    /**
     * A plain SMS we sent to a hidden number outside the secure section's
     * composer (a scheduled message): sealed as `{…, outgoing: true}` so the
     * secure section shows it in that conversation. No notification.
     */
    fun recordSent(
        context: Context,
        address: String,
        body: String,
        timestamp: Long,
        subscriptionId: Int,
    ): Boolean {
        val record = JSONObject().apply {
            put("k", SealedInbox.KIND_SMS)
            put("address", address)
            put("body", body)
            put("timestamp", timestamp)
            put("subscriptionId", subscriptionId)
            put("outgoing", true)
        }
        return SealedInbox.enqueue(context, SealedInbox.KIND_SMS, record)
    }

    /** Sends [body] to a hidden number with no provider row, and seals the copy. */
    fun sendPrivately(context: Context, address: String, body: String, subscriptionId: Int): Boolean {
        if (!ScheduledSmsWorker.sendSms(context, address, body, subscriptionId)) return false
        recordSent(context, address, body, System.currentTimeMillis(), subscriptionId)
        return true
    }
}
