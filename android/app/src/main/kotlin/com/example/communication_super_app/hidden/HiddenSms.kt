package com.example.communication_super_app.hidden

import android.content.Context
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
        if (!HiddenNumbers.isHidden(context, address)) return false
        val record = JSONObject().apply {
            put("k", SealedInbox.KIND_SMS)
            put("address", address)
            put("body", body)
            put("timestamp", timestamp)
            put("subscriptionId", subscriptionId)
        }
        if (!SealedInbox.enqueue(context, SealedInbox.KIND_SMS, record)) return false
        // A handshake or a receipt from a hidden contact announces nothing,
        // exactly as from anyone else.
        if (!SecureSmsInbox.isEncrypted(body) || SecureSmsInbox.announces(body)) {
            SecureSmsInbox.notifyArrived(context)
        }
        return true
    }
}
