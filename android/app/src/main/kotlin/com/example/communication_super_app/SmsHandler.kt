package com.example.communication_super_app

import android.app.Activity
import android.app.PendingIntent
import android.app.role.RoleManager
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.provider.Settings
import android.provider.Telephony
import android.telephony.ServiceState
import android.telephony.SmsManager
import android.telephony.SmsMessage

import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicBoolean

/**
 * High-performance SMS handler with native Android integration
 * - Handles SMS sending with multipart support
 * - Manages SMS receiving via BroadcastReceiver
 * - Supports dual-SIM devices
 * - Thread-safe and lifecycle-aware
 */
class SmsHandler(
    private val context: Context,
    private val activity: Activity?
) {
    companion object {
        private const val TAG = "SmsHandler"
        private const val SMS_SENT_ACTION = "SMS_SENT_ACTION"
        private const val SMS_DELIVERED_ACTION = "SMS_DELIVERED_ACTION"
        private const val EXTRA_TRACKING_ID = "tracking_id"
        private const val CHANNEL_SMS_METHOD = "com.example.communication_super_app/sms"
        private const val CHANNEL_SMS_EVENTS = "com.example.communication_super_app/sms_events"

        /** startActivityForResult code for the default-SMS-role request. */
        const val REQUEST_DEFAULT_SMS_ROLE = 9002

        /// True while the app's dynamic SMS_RECEIVED receiver is registered (i.e.
        /// the app process is alive and Flutter is handling reception). The
        /// manifest [IncomingSmsReceiver] reads this to avoid double-handling —
        /// it only acts on a cold start, when this is false.
        @JvmStatic
        @Volatile
        var isDynamicReceiverActive = false
    }

    private val coroutineScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var eventSink: EventChannel.EventSink? = null
    private val isReceiverRegistered = AtomicBoolean(false)

    /** Pending result of an in-flight default-SMS-role request; resolved in
     *  [handleRoleActivityResult] when the system dialog returns. */
    private var pendingRoleResult: MethodChannel.Result? = null
    
    // Broadcast receivers
    private val smsReceiver = SmsBroadcastReceiver()
    private val sentReceiver = SmsSentReceiver()
    private val deliveredReceiver = SmsDeliveredReceiver()

    /**
     * Inner class for receiving incoming SMS messages.
     *
     * **Everything here runs off the main thread**, and that is a latency fix,
     * not tidiness. A *dynamic* receiver's `onReceive` is delivered on the
     * app's main looper, and this one used to do the whole job there: a blocked
     * -number lookup that opens the app's SQLite file, then
     * [SmsNotifier.notifySms], which queries the contacts provider for a photo,
     * reads the conversation back out of the database, pushes a shortcut and
     * builds a notification. All of it before returning.
     *
     * The Flutter side pays for that twice over. `eventSink.success` is
     * dispatched with `Dispatchers.Main`, so it is **posted to the very looper
     * `onReceive` is occupying** — it cannot run until this method returns.
     * The message therefore reached the UI only after every one of those reads
     * had finished, and the whole app was frozen while they ran. That is the
     * reported "received messages arrive late"; sending never goes near this
     * path, which is why only the received ones were slow.
     *
     * `goAsync()` keeps the broadcast alive on a worker thread, so `onReceive`
     * returns in microseconds and Flutter is handed the message immediately —
     * the notification is then built in parallel instead of ahead of it.
     */
    inner class SmsBroadcastReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != "android.provider.Telephony.SMS_RECEIVED") return
            val app = context.applicationContext
            val pending = goAsync()
            Thread {
                try {
                    handle(app, intent)
                } catch (e: Exception) {
                    Log.e(TAG, "Error receiving SMS: ${e.message}", e)
                } finally {
                    pending.finish()
                }
            }.start()
        }

        private fun handle(context: Context, intent: Intent) {
            try {
                val bundle = intent.extras ?: return
                @Suppress("DEPRECATION")
                val pdus = bundle.get("pdus") as? Array<*> ?: return
                val format = bundle.getString("format") ?: "3gpp"

                // A multipart SMS arrives as several PDUs in ONE broadcast —
                // join them into a single message instead of emitting one
                // event (and one notification) per fragment.
                val parts = pdus.mapNotNull { pdu ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        SmsMessage.createFromPdu(pdu as ByteArray, format)
                    } else {
                        @Suppress("DEPRECATION")
                        SmsMessage.createFromPdu(pdu as ByteArray)
                    }
                }
                if (parts.isEmpty()) return

                val address = parts[0].originatingAddress ?: return
                val body = parts.joinToString("") { it.messageBody ?: "" }
                val timestamp = parts[0].timestampMillis

                // Blocked sender: drop silently — no event, no notification.
                if (BlockedNumbers.isBlocked(context, address)) {
                    Log.d(TAG, "Dropped live SMS from blocked number")
                    return
                }

                val data = mapOf(
                    "type" to "received",
                    "address" to address,
                    "body" to body,
                    "timestamp" to timestamp,
                    "subscriptionId" to getSubscriptionId(bundle)
                )

                // Send to Flutter via EventChannel (non-blocking)
                coroutineScope.launch(Dispatchers.Main) {
                    try {
                        eventSink?.success(data)
                        Log.d(TAG, "SMS received from: $address")
                    } catch (e: Exception) {
                        Log.e(TAG, "Error sending SMS to Flutter: ${e.message}")
                    }
                }

                // Native notification with inline reply / mark-read — the ONE
                // SMS notification pipeline (the Dart side no longer posts its
                // own for this path).
                SmsNotifier.notifySms(
                    context, address, body, timestamp,
                    BlockedNumbers.normalizeToThreadId(address),
                    getSubscriptionId(bundle),
                )
            } catch (e: Exception) {
                Log.e(TAG, "Error receiving SMS: ${e.message}", e)
            }
        }

        private fun getSubscriptionId(bundle: android.os.Bundle): Int {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                bundle.getInt("subscription", -1)
            } else {
                -1
            }
        }
    }

    /**
     * Sent-status receiver. The tracking id (the Dart-side message UUID) rides
     * in the PendingIntent extras; the outcome is streamed to Flutter as a
     * typed `status` event so the bubble's tick can advance (⏱ → ✓ → ✓✓) or
     * flip to failed.
     *
     * A multipart message broadcasts **once per part**. Only the last part to
     * report decides, and any failed part fails the message: a five-part SMS
     * whose third part the radio refused did not arrive, however cheerful the
     * other four were. [PartTally] does that counting.
     */
    inner class SmsSentReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val trackingId = intent.getStringExtra(EXTRA_TRACKING_ID) ?: return
            val ok = resultCode == Activity.RESULT_OK
            if (!ok) Log.e(TAG, "SMS send failed (resultCode=$resultCode)")
            when (sentTally.report(trackingId, ok)) {
                // Parts still outstanding. The tick advances anyway on the
                // first accepted part: the radio has taken the message, the
                // bubble should say so, and a broadcast that never arrives (a
                // part the framework drops, the process restarting mid-send)
                // must not strand the row at «در حال ارسال» for ever. A later
                // part that fails still overrides it below.
                PartTally.Outcome.PENDING -> if (ok) emitStatus(trackingId, "sent")
                PartTally.Outcome.OK -> emitStatus(trackingId, "sent")
                PartTally.Outcome.FAILED -> emitStatus(trackingId, "failed")
                // Already called failed; its remaining parts say nothing.
                PartTally.Outcome.SILENT -> Unit
            }
        }
    }

    /**
     * Delivery-report receiver — the ✓✓ on a sent bubble.
     *
     * **The broadcast's `resultCode` says nothing about delivery.** The
     * platform documents the delivery `PendingIntent` as carrying "the raw pdu
     * of the status report" in the `"pdu"` extra, and that PDU's TP-Status is
     * the only thing that knows whether the message arrived. On the RILs this
     * app runs on the code is `RESULT_OK` for *every* status report the network
     * sends — including «temporary error, still trying» and «permanent failure,
     * gave up» — so trusting it is exactly the reported bug: the second tick
     * appeared for messages that had not been delivered, and sometimes for
     * messages that never would be.
     *
     * TP-Status is TS 23.040 §9.2.3.15, read the way AOSP Messaging reads it:
     *
     * * `0x00…0x1F` — delivered (0x00 is «received by the SME»),
     * * `0x20…0x3F` — still trying; the network will send another report, so
     *   the bubble stays at ✓ and says nothing yet,
     * * anything else — failed, permanently.
     *
     * CDMA reports do not carry TP-Status at all; `SmsMessage.getStatus()`
     * returns `STATUS_ON_ICC_*` there, which is not this field, so a CDMA
     * report is treated as a plain delivery (the app's target networks are
     * GSM/UMTS/LTE).
     *
     * A multipart message reports per part; ✓✓ needs **all** of them, which is
     * the same [PartTally] the sent receiver uses.
     */
    inner class SmsDeliveredReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val trackingId = intent.getStringExtra(EXTRA_TRACKING_ID) ?: return
            when (readDeliveryStatus(intent)) {
                DeliveryOutcome.PENDING -> {
                    Log.d(TAG, "status report: still trying, leaving the tick alone")
                }
                DeliveryOutcome.DELIVERED ->
                    when (deliveredTally.report(trackingId, true)) {
                        // ✓✓ only once EVERY part has been delivered.
                        PartTally.Outcome.PENDING,
                        PartTally.Outcome.SILENT -> Unit
                        PartTally.Outcome.OK -> emitStatus(trackingId, "delivered")
                        PartTally.Outcome.FAILED -> emitStatus(trackingId, "failed")
                    }
                DeliveryOutcome.FAILED -> {
                    Log.e(TAG, "SMS delivery failed (status report)")
                    // Through the tally, so a message already reported failed
                    // does not say so again for each remaining part.
                    when (deliveredTally.report(trackingId, false)) {
                        PartTally.Outcome.FAILED -> emitStatus(trackingId, "failed")
                        else -> Unit
                    }
                }
            }
        }
    }

    private enum class DeliveryOutcome { DELIVERED, PENDING, FAILED }

    /**
     * Reads TP-Status out of a status-report broadcast.
     *
     * A PDU that cannot be parsed (an OEM that does not put one in the extras)
     * falls back to [DeliveryOutcome.DELIVERED] — the report only exists
     * because the network sent one, and the alternative is a tick that never
     * advances on those phones.
     */
    private fun readDeliveryStatus(intent: Intent): DeliveryOutcome {
        val pdu = intent.getByteArrayExtra("pdu") ?: return DeliveryOutcome.DELIVERED
        val format = intent.getStringExtra("format")
        val message = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && format != null) {
                SmsMessage.createFromPdu(pdu, format)
            } else {
                @Suppress("DEPRECATION")
                SmsMessage.createFromPdu(pdu)
            }
        } catch (e: Exception) {
            Log.w(TAG, "unreadable status report: ${e.message}")
            null
        } ?: return DeliveryOutcome.DELIVERED

        // Not a GSM report: `getStatus()` is not TP-Status there.
        if (format == "3gpp2") return DeliveryOutcome.DELIVERED
        // `getStatus()` only carries TP-Status for an actual status report; on
        // anything else it answers with the ICC storage status, which would be
        // read here as a delivery verdict it is not.
        if (!message.isStatusReportMessage) return DeliveryOutcome.DELIVERED

        val status = message.status
        return when {
            status < 0x20 -> DeliveryOutcome.DELIVERED
            status < 0x40 -> DeliveryOutcome.PENDING
            else -> DeliveryOutcome.FAILED
        }
    }

    /**
     * Counts the parts of one multipart message so a per-part broadcast becomes
     * one answer about the message.
     *
     * `sendMultipartTextMessage` fires the PendingIntent once per part, and the
     * old code emitted a status on each — so a three-part SMS turned its bubble
     * ✓✓ as soon as the *first* part was acknowledged, and a message whose
     * later part failed had already claimed success.
     *
     * Entries are dropped as soon as they resolve, and stale ones (a report
     * that never arrives — the network is not obliged to send one) are swept on
     * insert, so this cannot grow without bound.
     */
    class PartTally {
        enum class Outcome {
            /** Parts still outstanding, none has failed. */
            PENDING,

            /** Every part reported, all of them accepted. */
            OK,

            /** The first failure of this message. */
            FAILED,

            /**
             * Say nothing: this message has already been called failed.
             *
             * This case exists because of a bug in the first version, which
             * dropped the entry on the first failure — so the *next* part's
             * report found no entry, was treated as a message of its own, and
             * flipped a message that had just been marked «ارسال نشد» back to
             * ✓. A verdict of failure is final for the whole message; the
             * remaining parts are counted only so the entry can be retired.
             */
            SILENT,
        }

        private class Entry(val total: Int, val at: Long) {
            var seen = 0
            var failed = false
        }

        private val entries = HashMap<String, Entry>()

        /** How many parts [trackingId] was split into. */
        @Synchronized
        fun expect(trackingId: String, parts: Int) {
            if (trackingId.isEmpty()) return
            sweep()
            entries[trackingId] = Entry(parts, System.currentTimeMillis())
        }

        /** Folds one part's outcome in and says whether the message is decided. */
        @Synchronized
        fun report(trackingId: String, ok: Boolean): Outcome {
            // No entry: a report for a message this process did not send (the
            // app was restarted), or one already retired. One report, one
            // answer.
            val entry = entries[trackingId] ?: return if (ok) Outcome.OK else Outcome.FAILED
            val alreadyFailed = entry.failed
            entry.seen++
            if (!ok) entry.failed = true
            // Retire the entry only once every part has spoken, so a message
            // that failed cannot be mistaken for a fresh one by its own
            // stragglers.
            if (entry.seen >= entry.total) entries.remove(trackingId)
            return when {
                alreadyFailed -> Outcome.SILENT
                entry.failed -> Outcome.FAILED
                entry.seen >= entry.total -> Outcome.OK
                else -> Outcome.PENDING
            }
        }

        private fun sweep() {
            if (entries.size < 64) return
            val cutoff = System.currentTimeMillis() - STALE_MS
            entries.entries.removeAll { it.value.at < cutoff }
        }

        private companion object {
            /** A status report that has not arrived in an hour is not coming. */
            const val STALE_MS = 60L * 60_000
        }
    }

    private val sentTally = PartTally()
    private val deliveredTally = PartTally()

    /** Streams a typed status event to Flutter over the SMS EventChannel. */
    private fun emitStatus(trackingId: String, status: String) {
        coroutineScope.launch(Dispatchers.Main) {
            try {
                eventSink?.success(
                    mapOf(
                        "type" to "status",
                        "id" to trackingId,
                        "status" to status,
                    )
                )
            } catch (e: Exception) {
                Log.e(TAG, "Error sending status to Flutter: ${e.message}")
            }
        }
    }

    /**
     * Register SMS receiver for incoming messages
     */
    fun registerReceiver() {
        if (isReceiverRegistered.getAndSet(true)) {
            Log.d(TAG, "SMS receiver already registered")
            return
        }

        try {
            // Register SMS receiver.
            // SMS_RECEIVED is a SYSTEM broadcast (sent from a different UID), so
            // the dynamic receiver MUST be EXPORTED on Android 13+. Registering it
            // NOT_EXPORTED silently drops system broadcasts — the app would never
            // see incoming SMS (no persist, no notification, no UI refresh).
            //
            // Exported, but NOT open: the registration carries the
            // `BROADCAST_SMS` permission, which only the system holds. Without
            // it an exported receiver on this action accepts an
            // `android.provider.Telephony.SMS_RECEIVED` broadcast from ANY app
            // on the phone — a forged message, persisted into the inbox and
            // posted as a notification from a sender the user has no reason to
            // doubt. The manifest twin (`IncomingSmsReceiver`) has always been
            // declared with this permission; the dynamic one had not.
            val smsFilter = IntentFilter("android.provider.Telephony.SMS_RECEIVED").apply {
                priority = 999 // High priority
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(
                    smsReceiver,
                    smsFilter,
                    android.Manifest.permission.BROADCAST_SMS,
                    null,
                    Context.RECEIVER_EXPORTED,
                )
            } else {
                context.registerReceiver(
                    smsReceiver,
                    smsFilter,
                    android.Manifest.permission.BROADCAST_SMS,
                    null,
                )
            }

            // Register sent/delivered receivers
            val sentFilter = IntentFilter(SMS_SENT_ACTION)
            val deliveredFilter = IntentFilter(SMS_DELIVERED_ACTION)
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(sentReceiver, sentFilter, Context.RECEIVER_NOT_EXPORTED)
                context.registerReceiver(deliveredReceiver, deliveredFilter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(sentReceiver, sentFilter)
                context.registerReceiver(deliveredReceiver, deliveredFilter)
            }

            isDynamicReceiverActive = true
            Log.d(TAG, "SMS receivers registered successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register SMS receiver: ${e.message}", e)
            isReceiverRegistered.set(false)
        }
    }

    /**
     * Unregister SMS receiver
     */
    fun unregisterReceiver() {
        if (!isReceiverRegistered.getAndSet(false)) {
            return
        }

        try {
            context.unregisterReceiver(smsReceiver)
            context.unregisterReceiver(sentReceiver)
            context.unregisterReceiver(deliveredReceiver)
            isDynamicReceiverActive = false
            Log.d(TAG, "SMS receivers unregistered successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to unregister SMS receiver: ${e.message}", e)
        }
    }

    /**
     * Send SMS with multipart support
     * Executes on background thread to avoid blocking UI
     */
    suspend fun sendSms(
        phoneNumber: String,
        message: String,
        subscriptionId: Int = -1,
        trackingId: String = "",
        /** When false no delivery PendingIntent is attached, so the carrier is
         *  never asked for a delivery report («گزارش تحویل» in Settings). */
        requestDeliveryReport: Boolean = true,
    ): Result<Map<String, Any>> = withContext(Dispatchers.IO) {
        try {
            if (phoneNumber.isBlank()) {
                return@withContext Result.failure(IllegalArgumentException("Phone number cannot be empty"))
            }

            if (message.isBlank()) {
                return@withContext Result.failure(IllegalArgumentException("Message cannot be empty"))
            }

            // Pre-flight checks before calling the fire-and-forget sendTextMessage.
            // Without these, Android queues the SMS silently and the Flutter
            // side never knows it couldn't be sent.
            if (!hasActiveSim()) {
                return@withContext Result.failure(Exception("NO_SIM_CARD"))
            }
            // Checked against the SIM this message will actually go out on, not
            // the system default. Reading the default's ServiceState made the
            // two cards lie about each other: sending on SIM 2 was refused with
            // NO_SERVICE whenever SIM 1 had no signal, and a send on a SIM that
            // really had none sailed past the check and sat in the radio queue
            // — which is what "it sent, but very late" looks like.
            if (!isInService(subscriptionId)) {
                return@withContext Result.failure(Exception("NO_SERVICE"))
            }

            val smsManager = getSmsManager(subscriptionId)

            // Create pending intents for sent/delivered status.
            // Android 14 (U / API 34)+ forbids a PendingIntent built from an
            // IMPLICIT Intent together with FLAG_MUTABLE — it throws and the whole
            // send fails. These status intents don't need to be mutable (the
            // result is delivered via the broadcast result code), so use
            // FLAG_IMMUTABLE and make them explicit by scoping to our package.
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            // Per-message PendingIntents: a unique requestCode + the tracking
            // id in the extras, so concurrent sends report to the right bubble.
            val requestCode = if (trackingId.isEmpty()) 0 else trackingId.hashCode()
            val sentIntent = PendingIntent.getBroadcast(
                context, requestCode,
                Intent(SMS_SENT_ACTION).setPackage(context.packageName)
                    .putExtra(EXTRA_TRACKING_ID, trackingId),
                flags
            )
            val deliveredIntent = if (requestDeliveryReport) {
                PendingIntent.getBroadcast(
                    context, requestCode,
                    Intent(SMS_DELIVERED_ACTION).setPackage(context.packageName)
                        .putExtra(EXTRA_TRACKING_ID, trackingId),
                    flags
                )
            } else {
                null
            }

            // Handle multipart messages
            val parts = smsManager.divideMessage(message)

            // Registered BEFORE the send: the radio can acknowledge a part
            // before this coroutine gets another slice, and a report that
            // arrives with no tally is treated as the whole message.
            sentTally.expect(trackingId, parts.size)
            if (requestDeliveryReport) deliveredTally.expect(trackingId, parts.size)

            if (parts.size == 1) {
                // Single part message
                smsManager.sendTextMessage(
                    phoneNumber,
                    null,
                    message,
                    sentIntent,
                    deliveredIntent
                )
            } else {
                // Multipart message
                val sentIntents = ArrayList<PendingIntent>()
                val deliveredIntents = ArrayList<PendingIntent>()

                repeat(parts.size) {
                    sentIntents.add(sentIntent)
                    deliveredIntent?.let { deliveredIntents.add(it) }
                }

                smsManager.sendMultipartTextMessage(
                    phoneNumber,
                    null,
                    parts,
                    sentIntents,
                    // The list must be null (not empty) to mean "no reports".
                    deliveredIntents.takeIf { it.isNotEmpty() }
                )
            }

            val timestamp = System.currentTimeMillis()

            // Write-through: while this app is the default SMS app the system
            // does NOT store outgoing messages — without this insert the sent
            // SMS would be invisible to every other SMS app on the phone.
            // The row records the SIM that was actually asked for. When the
            // caller passed -1 the platform picks the default, so resolve it
            // now rather than storing "unknown" for a message we could name.
            val usedSubscriptionId = if (subscriptionId != -1) {
                subscriptionId
            } else {
                com.example.communication_super_app.sim.SimRegistry
                    .defaultSmsSubscriptionId()
            }
            val deviceId =
                writeSentToProvider(phoneNumber, message, timestamp, usedSubscriptionId)

            val result = mapOf(
                "success" to true,
                "phoneNumber" to phoneNumber,
                "messageLength" to message.length,
                "parts" to parts.size,
                "subscriptionId" to usedSubscriptionId,
                "timestamp" to timestamp,
                "deviceId" to deviceId
            )

            Log.d(TAG, "SMS sent to $phoneNumber (${parts.size} parts)")
            Result.success(result)
        } catch (e: SecurityException) {
            Log.e(TAG, "SMS permission denied: ${e.message}", e)
            // Re-wrap so the MethodChannel handler can detect it via instanceof check.
            Result.failure(e)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send SMS: ${e.message}", e)
            // Check for RESULT_ERROR_NO_SERVICE style errors that surface as
            // generic exceptions on some devices.
            val msg = e.message ?: ""
            if (msg.contains("no service", ignoreCase = true) ||
                msg.contains("radio off", ignoreCase = true)) {
                Result.failure(Exception("NO_SERVICE"))
            } else {
                Result.failure(e)
            }
        }
    }

    /**
     * Returns true if the device has cellular service (not in airplane mode
     * and the network reports STATE_IN_SERVICE).
     *
     * SmsManager.sendTextMessage() is fire-and-forget; it does not throw when
     * there is no signal.  This pre-flight check lets Flutter show a clear
     * error instead of optimistically adding a message that was never queued.
     *
     * READ_PHONE_STATE is declared in the manifest and is requested at runtime
     * by the Flutter side before any send is attempted.  If the permission is
     * somehow missing, the check falls through to true (send proceeds naturally
     * and will fail via the sent PendingIntent).
     */
    private fun isInService(subscriptionId: Int = -1): Boolean {
        // Airplane mode check requires no runtime permission.
        val isAirplaneMode = Settings.Global.getInt(
            context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
        if (isAirplaneMode) return false

        return try {
            val base = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            // Per-SIM manager when a card was named; a bad id would throw, so
            // fall back to the default rather than blocking the send.
            val tm = if (
                subscriptionId != -1 &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.N
            ) {
                runCatching { base?.createForSubscriptionId(subscriptionId) }.getOrNull() ?: base
            } else {
                base
            }
            val state = tm?.serviceState?.state
            // null means we couldn't read the state – assume in service
            state == null || state == ServiceState.STATE_IN_SERVICE
        } catch (e: SecurityException) {
            Log.w(TAG, "READ_PHONE_STATE not granted; skipping service-state check")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Service-state check failed: ${e.message}")
            true
        }
    }

    /**
     * Returns true if the device has at least one active SIM card.
     * Used to give a clear error to the user instead of a silent failure.
     */
    private fun hasActiveSim(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) return true
        return try {
            val subscriptionManager = context.getSystemService(
                Context.TELEPHONY_SUBSCRIPTION_SERVICE
            ) as? SubscriptionManager
            (subscriptionManager?.activeSubscriptionInfoCount ?: 0) > 0
        } catch (e: SecurityException) {
            // READ_PHONE_STATE not granted; assume SIM present and let the
            // actual send surface the real error.
            true
        }
    }

    // ── SMS provider queries (mirror-sync source) ────────────────────────────
    // Replaces the `another_telephony` plugin, whose global
    // onRequestPermissionsResult listener double-replied a MethodChannel
    // result ("Reply already submitted") and crashed the app whenever a
    // telephony call overlapped any permission dialog.

    /** content://sms/<box> rows, newest first. limit <= 0 means no limit. */
    fun querySms(box: String, limit: Int): List<Map<String, Any?>> {
        val uri = if (box == "sent") Telephony.Sms.Sent.CONTENT_URI
                  else Telephony.Sms.Inbox.CONTENT_URI
        val out = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(
            uri,
            // SUBSCRIPTION_ID only exists from API 22; asking for it below that
            // makes the whole query throw.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                arrayOf(
                    Telephony.Sms._ID,
                    Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY,
                    Telephony.Sms.DATE,
                    Telephony.Sms.SUBSCRIPTION_ID,
                )
            } else {
                arrayOf(
                    Telephony.Sms._ID,
                    Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY,
                    Telephony.Sms.DATE,
                )
            },
            null, null,
            "${Telephony.Sms.DATE} DESC",
        )?.use { c ->
            val idIdx = c.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addrIdx = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIdx = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIdx = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
            // getColumnIndex, not OrThrow: OEM providers have been seen to drop
            // the column even on supported API levels.
            val subIdx = c.getColumnIndex(Telephony.Sms.SUBSCRIPTION_ID)
            while (c.moveToNext()) {
                if (limit > 0 && out.size >= limit) break
                val subscriptionId =
                    if (subIdx >= 0 && !c.isNull(subIdx)) c.getInt(subIdx) else null
                out.add(
                    mapOf(
                        "id" to c.getLong(idIdx),
                        "address" to (c.getString(addrIdx) ?: ""),
                        "body" to (c.getString(bodyIdx) ?: ""),
                        "date" to c.getLong(dateIdx),
                        // -1 is the provider's own "unset"; hand it back as
                        // null so Dart never stores it as a real SIM.
                        "subscriptionId" to subscriptionId?.takeIf { it >= 0 },
                    )
                )
            }
        }
        return out
    }

    /**
     * ALL row ids of a box, **newest first** — a tiny payload that drives both
     * the deletion diff and the import diff.
     *
     * The order matters for the import: the sync fetches the rows it is missing
     * in this order, so the newest messages land first and the inbox fills from
     * the top while an old, long mailbox is still being read.
     */
    fun querySmsIds(box: String): List<Long> {
        val uri = if (box == "sent") Telephony.Sms.Sent.CONTENT_URI
                  else Telephony.Sms.Inbox.CONTENT_URI
        val out = ArrayList<Long>()
        context.contentResolver.query(
            uri, arrayOf(Telephony.Sms._ID), null, null,
            "${Telephony.Sms.DATE} DESC",
        )?.use { c ->
            while (c.moveToNext()) out.add(c.getLong(0))
        }
        return out
    }

    /**
     * The rows named by [ids], in the order given.
     *
     * This is what makes the import **complete** instead of "the most recent N
     * per box". Capping the content query at 500 rows per box meant the inbox
     * — which on a real phone holds far more traffic than the sent box — was
     * only mirrored a few weeks back, while the (much sparser) sent box reached
     * months: exactly the "it only shows MY messages in old conversations"
     * report. The sync now asks which ids it does not have and fetches only
     * those, so the first run walks the whole mailbox and every later one costs
     * a single id query.
     */
    fun querySmsByIds(box: String, ids: List<Long>): List<Map<String, Any?>> {
        if (ids.isEmpty()) return emptyList()
        val uri = if (box == "sent") Telephony.Sms.Sent.CONTENT_URI
                  else Telephony.Sms.Inbox.CONTENT_URI
        val projection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            arrayOf(
                Telephony.Sms._ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.SUBSCRIPTION_ID,
            )
        } else {
            arrayOf(
                Telephony.Sms._ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
            )
        }
        val byId = HashMap<Long, Map<String, Any?>>(ids.size)
        val selection = "${Telephony.Sms._ID} IN (${ids.joinToString(",")})"
        context.contentResolver.query(uri, projection, selection, null, null)
            ?.use { c ->
                val idIdx = c.getColumnIndexOrThrow(Telephony.Sms._ID)
                val addrIdx = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
                val bodyIdx = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
                val dateIdx = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
                val subIdx = c.getColumnIndex(Telephony.Sms.SUBSCRIPTION_ID)
                while (c.moveToNext()) {
                    val id = c.getLong(idIdx)
                    val subscriptionId =
                        if (subIdx >= 0 && !c.isNull(subIdx)) c.getInt(subIdx) else null
                    byId[id] = mapOf(
                        "id" to id,
                        "address" to (c.getString(addrIdx) ?: ""),
                        "body" to (c.getString(bodyIdx) ?: ""),
                        "date" to c.getLong(dateIdx),
                        "subscriptionId" to subscriptionId?.takeIf { it >= 0 },
                    )
                }
            }
        // Hand them back in the caller's order — a row deleted between the id
        // query and this one simply drops out.
        return ids.mapNotNull(byId::get)
    }

    // ── Default SMS app role ─────────────────────────────────────────────────

    /** True when this app currently holds the default-SMS-app role. */
    fun isDefaultSmsApp(): Boolean {
        // On Q+ the role is the source of truth; some OEMs report a stale
        // package from getDefaultSmsPackage right after the role changes.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = context.getSystemService(RoleManager::class.java)
            if (roleManager?.isRoleHeld(RoleManager.ROLE_SMS) == true) return true
        }
        return Telephony.Sms.getDefaultSmsPackage(context) == context.packageName
    }

    /**
     * Launches the system "set default SMS app" dialog. The outcome lands in
     * [handleRoleActivityResult] (forwarded from MainActivity.onActivityResult).
     */
    private fun requestDefaultSmsRole(result: MethodChannel.Result) {
        if (isDefaultSmsApp()) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }
        val intent: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = context.getSystemService(RoleManager::class.java)
            if (roleManager?.isRoleAvailable(RoleManager.ROLE_SMS) == true) {
                roleManager.createRequestRoleIntent(RoleManager.ROLE_SMS)
            } else null
        } else {
            Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).apply {
                putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, context.packageName)
            }
        }
        if (intent == null) {
            result.error("ROLE_UNAVAILABLE", "SMS role not available on this device", null)
            return
        }
        // Only one request at a time; resolve a stale pending one as cancelled.
        pendingRoleResult?.success(false)
        pendingRoleResult = result
        try {
            act.startActivityForResult(intent, REQUEST_DEFAULT_SMS_ROLE)
        } catch (e: Exception) {
            pendingRoleResult = null
            result.error("ROLE_REQUEST_FAILED", e.message, null)
        }
    }

    /** Called from MainActivity.onActivityResult. Returns true when consumed. */
    fun handleRoleActivityResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_DEFAULT_SMS_ROLE) return false
        // Don't trust resultCode — some OEM dialogs return CANCELED even on
        // success. The role state itself is the source of truth.
        pendingRoleResult?.success(isDefaultSmsApp())
        pendingRoleResult = null
        return true
    }

    // ── SMS provider write-through (only effective while default) ───────────

    /**
     * Inserts a just-sent message into the device SMS provider so it shows up
     * in every SMS app. Only the default SMS app may write; otherwise the
     * insert is skipped (Android would silently drop or reject it anyway).
     * Returns the provider row id, or -1.
     */
    fun writeSentToProvider(
        address: String,
        body: String,
        timestamp: Long,
        subscriptionId: Int = -1,
    ): Long {
        if (!isDefaultSmsApp()) return -1
        return try {
            val values = ContentValues().apply {
                put(Telephony.Sms.ADDRESS, address)
                put(Telephony.Sms.BODY, body)
                put(Telephony.Sms.DATE, timestamp)
                put(Telephony.Sms.READ, 1)
                // Which SIM it went out on. Every other SMS app on the phone
                // reads this column to draw its own SIM badge, so omitting it
                // makes our sent messages look SIM-less in theirs.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1 &&
                    subscriptionId != -1
                ) {
                    put(Telephony.Sms.SUBSCRIPTION_ID, subscriptionId)
                }
            }
            val uri = context.contentResolver.insert(Telephony.Sms.Sent.CONTENT_URI, values)
            uri?.lastPathSegment?.toLongOrNull() ?: -1
        } catch (e: Exception) {
            Log.e(TAG, "writeSentToProvider failed: ${e.message}")
            -1
        }
    }

    /**
     * Deletes messages from the device SMS provider. Each spec identifies one
     * message either by provider row id (`deviceId`) or by content match
     * (`address` + `body` + `timestamp`, with a small clock tolerance because
     * provider DATE and our timestamp can differ by the send/receive latency).
     * Returns the number of provider rows deleted.
     */
    fun deleteSmsFromProvider(specs: List<Map<String, Any?>>): Int {
        if (!isDefaultSmsApp()) return 0
        var deleted = 0
        val resolver = context.contentResolver
        for (spec in specs) {
            try {
                val deviceId = (spec["deviceId"] as? Number)?.toLong()
                if (deviceId != null && deviceId > 0) {
                    deleted += resolver.delete(
                        Telephony.Sms.CONTENT_URI,
                        "${Telephony.Sms._ID} = ?",
                        arrayOf(deviceId.toString())
                    )
                    continue
                }
                val body = spec["body"] as? String ?: continue
                val timestamp = (spec["timestamp"] as? Number)?.toLong() ?: continue
                // ±10 s window: covers provider DATE vs app timestamp skew.
                deleted += resolver.delete(
                    Telephony.Sms.CONTENT_URI,
                    "${Telephony.Sms.BODY} = ? AND ${Telephony.Sms.DATE} BETWEEN ? AND ?",
                    arrayOf(body, (timestamp - 10_000).toString(), (timestamp + 10_000).toString())
                )
            } catch (e: Exception) {
                Log.e(TAG, "deleteSmsFromProvider spec failed: ${e.message}")
            }
        }
        return deleted
    }

    /**
     * Deletes an entire conversation from the provider: every row whose
     * normalized address ends with the same national significant number.
     * Addresses are stored inconsistently (+98912…, 0912…, 912…), so rows are
     * matched in code, not in SQL. Returns the number of rows deleted.
     */
    fun deleteSmsThreadFromProvider(address: String): Int {
        if (!isDefaultSmsApp()) return 0
        val target = significantDigits(address)
        if (target.isEmpty()) return 0
        val resolver = context.contentResolver
        val ids = ArrayList<String>()
        try {
            resolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS),
                null, null, null
            )?.use { c ->
                val idIdx = c.getColumnIndexOrThrow(Telephony.Sms._ID)
                val addrIdx = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
                while (c.moveToNext()) {
                    val rowAddr = c.getString(addrIdx) ?: continue
                    if (significantDigits(rowAddr) == target) {
                        ids.add(c.getString(idIdx))
                    }
                }
            }
            var deleted = 0
            // Chunked IN() delete to stay well under SQLite's variable limit.
            ids.chunked(500).forEach { chunk ->
                val placeholders = chunk.joinToString(",") { "?" }
                deleted += resolver.delete(
                    Telephony.Sms.CONTENT_URI,
                    "${Telephony.Sms._ID} IN ($placeholders)",
                    chunk.toTypedArray()
                )
            }
            return deleted
        } catch (e: Exception) {
            Log.e(TAG, "deleteSmsThreadFromProvider failed: ${e.message}")
            return 0
        }
    }

    /** Last 10 digits — the national significant number, comparable across
     *  +98912…, 0912…, 912… representations (mirrors PhoneNormalizer). */
    private fun significantDigits(phone: String): String {
        val digits = phone.filter { it.isDigit() }
        return if (digits.length > 10) digits.takeLast(10) else digits
    }

    /**
     * Get SMS manager for specific subscription (dual-SIM support)
     */
    private fun getSmsManager(subscriptionId: Int): SmsManager {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1 && subscriptionId != -1) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
                    .createForSubscriptionId(subscriptionId)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
            }
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
        }
    }

    /**
     * Set up MethodChannel for SMS operations
     */
    fun setupMethodChannel(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> {
                    val phoneNumber = call.argument<String>("phoneNumber")
                    val message = call.argument<String>("message")
                    val subscriptionId = call.argument<Int>("subscriptionId") ?: -1
                    val trackingId = call.argument<String>("trackingId") ?: ""
                    val deliveryReport =
                        call.argument<Boolean>("deliveryReport") ?: true

                    if (phoneNumber == null || message == null) {
                        result.error("INVALID_ARGUMENTS", "Phone number and message are required", null)
                        return@setMethodCallHandler
                    }

                    coroutineScope.launch {
                        try {
                            val sendResult = sendSms(
                                phoneNumber,
                                message,
                                subscriptionId,
                                trackingId,
                                deliveryReport,
                            )
                            
                            if (sendResult.isSuccess) {
                                result.success(sendResult.getOrNull())
                            } else {
                                val error = sendResult.exceptionOrNull()
                                val errorMsg = error?.message ?: ""
                                // Map well-known error messages to typed codes so
                                // Flutter can show a localized user-facing message.
                                val code = when {
                                    errorMsg == "NO_SIM_CARD" -> "NO_SIM_CARD"
                                    errorMsg == "NO_SERVICE" -> "NO_SERVICE"
                                    error is SecurityException -> "PERMISSION_DENIED"
                                    else -> "SMS_SEND_FAILED"
                                }
                                result.error(code, errorMsg, null)
                            }
                        } catch (e: Exception) {
                            result.error("SMS_SEND_FAILED", e.message, null)
                        }
                    }
                }
                
                "registerReceiver" -> {
                    try {
                        registerReceiver()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("REGISTER_ERROR", e.message, e.stackTraceToString())
                    }
                }

                // Provider reads run on IO — a big inbox must not jank the UI.
                "querySms" -> {
                    val box = call.argument<String>("box") ?: "inbox"
                    val limit = call.argument<Int>("limit") ?: 0
                    coroutineScope.launch(Dispatchers.IO) {
                        try {
                            val rows = querySms(box, limit)
                            withContext(Dispatchers.Main) { result.success(rows) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("QUERY_FAILED", e.message, null)
                            }
                        }
                    }
                }

                "querySmsIds" -> {
                    val box = call.argument<String>("box") ?: "inbox"
                    coroutineScope.launch(Dispatchers.IO) {
                        try {
                            val ids = querySmsIds(box)
                            withContext(Dispatchers.Main) { result.success(ids) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("QUERY_FAILED", e.message, null)
                            }
                        }
                    }
                }

                "querySmsByIds" -> {
                    val box = call.argument<String>("box") ?: "inbox"
                    val ids = call.argument<List<Number>>("ids").orEmpty()
                        .map { it.toLong() }
                    coroutineScope.launch(Dispatchers.IO) {
                        try {
                            val rows = querySmsByIds(box, ids)
                            withContext(Dispatchers.Main) { result.success(rows) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("QUERY_FAILED", e.message, null)
                            }
                        }
                    }
                }

                "isDefaultSmsApp" -> result.success(isDefaultSmsApp())

                "requestDefaultSmsRole" -> requestDefaultSmsRole(result)

                // Fallback when the role dialog is unavailable or auto-denied
                // (system permanently auto-denies after two refusals): send the
                // user to Settings → Default apps to pick this app manually.
                "openDefaultAppsSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_FAILED", e.message, null)
                    }
                }

                // Deletes provider rows by spec list [{deviceId?|body+timestamp}].
                "deleteSmsFromProvider" -> {
                    val specs = call.argument<List<Map<String, Any?>>>("messages")
                    if (specs == null) {
                        result.error("INVALID_ARGUMENTS", "messages required", null)
                        return@setMethodCallHandler
                    }
                    coroutineScope.launch(Dispatchers.IO) {
                        val deleted = deleteSmsFromProvider(specs)
                        withContext(Dispatchers.Main) { result.success(deleted) }
                    }
                }

                // Deletes a whole conversation (all rows for an address).
                "deleteSmsThreadFromProvider" -> {
                    val address = call.argument<String>("address")
                    if (address.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENTS", "address required", null)
                        return@setMethodCallHandler
                    }
                    coroutineScope.launch(Dispatchers.IO) {
                        val deleted = deleteSmsThreadFromProvider(address)
                        withContext(Dispatchers.Main) { result.success(deleted) }
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    /**
     * Set up EventChannel for SMS reception
     */
    fun setupEventChannel(channel: EventChannel) {
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                Log.d(TAG, "EventChannel listener attached")
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                Log.d(TAG, "EventChannel listener cancelled")
            }
        })
    }

    /**
     * Clean up resources
     */
    fun dispose() {
        unregisterReceiver()
        coroutineScope.cancel()
        eventSink = null
        Log.d(TAG, "SmsHandler disposed")
    }
}



