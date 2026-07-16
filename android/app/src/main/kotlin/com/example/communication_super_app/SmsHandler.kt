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
import android.telephony.SubscriptionInfo
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
     * Inner class for receiving incoming SMS messages
     */
    inner class SmsBroadcastReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != "android.provider.Telephony.SMS_RECEIVED") return

            try {
                val bundle = intent.extras ?: return
                @Suppress("DEPRECATION")
                val pdus = bundle.get("pdus") as? Array<*> ?: return
                val format = bundle.getString("format") ?: "3gpp"

                for (pdu in pdus) {
                    val message = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        SmsMessage.createFromPdu(pdu as ByteArray, format)
                    } else {
                        @Suppress("DEPRECATION")
                        SmsMessage.createFromPdu(pdu as ByteArray)
                    }

                    val data = mapOf(
                        "address" to (message.originatingAddress ?: ""),
                        "body" to (message.messageBody ?: ""),
                        "timestamp" to message.timestampMillis,
                        "subscriptionId" to getSubscriptionId(bundle)
                    )

                    // Send to Flutter via EventChannel (non-blocking)
                    coroutineScope.launch(Dispatchers.Main) {
                        try {
                            eventSink?.success(data)
                            Log.d(TAG, "SMS received from: ${message.originatingAddress}")
                        } catch (e: Exception) {
                            Log.e(TAG, "Error sending SMS to Flutter: ${e.message}")
                        }
                    }
                }
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
     * Inner class for SMS sent status
     */
    inner class SmsSentReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (resultCode) {
                Activity.RESULT_OK -> {
                    Log.d(TAG, "SMS sent successfully")
                }
                SmsManager.RESULT_ERROR_GENERIC_FAILURE -> {
                    Log.e(TAG, "SMS send failed: Generic failure")
                }
                SmsManager.RESULT_ERROR_NO_SERVICE -> {
                    Log.e(TAG, "SMS send failed: No service")
                }
                SmsManager.RESULT_ERROR_NULL_PDU -> {
                    Log.e(TAG, "SMS send failed: Null PDU")
                }
                SmsManager.RESULT_ERROR_RADIO_OFF -> {
                    Log.e(TAG, "SMS send failed: Radio off")
                }
            }
        }
    }

    /**
     * Inner class for SMS delivery status
     */
    inner class SmsDeliveredReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (resultCode) {
                Activity.RESULT_OK -> {
                    Log.d(TAG, "SMS delivered successfully")
                }
                else -> {
                    Log.e(TAG, "SMS delivery failed")
                }
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
            val smsFilter = IntentFilter("android.provider.Telephony.SMS_RECEIVED").apply {
                priority = 999 // High priority
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(smsReceiver, smsFilter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(smsReceiver, smsFilter)
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
        subscriptionId: Int = -1
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
            if (!isInService()) {
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

            val sentIntent = PendingIntent.getBroadcast(
                context, 0,
                Intent(SMS_SENT_ACTION).setPackage(context.packageName), flags
            )
            val deliveredIntent = PendingIntent.getBroadcast(
                context, 0,
                Intent(SMS_DELIVERED_ACTION).setPackage(context.packageName), flags
            )

            // Handle multipart messages
            val parts = smsManager.divideMessage(message)
            
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
                    deliveredIntents.add(deliveredIntent)
                }
                
                smsManager.sendMultipartTextMessage(
                    phoneNumber,
                    null,
                    parts,
                    sentIntents,
                    deliveredIntents
                )
            }

            val timestamp = System.currentTimeMillis()

            // Write-through: while this app is the default SMS app the system
            // does NOT store outgoing messages — without this insert the sent
            // SMS would be invisible to every other SMS app on the phone.
            val deviceId = writeSentToProvider(phoneNumber, message, timestamp)

            val result = mapOf(
                "success" to true,
                "phoneNumber" to phoneNumber,
                "messageLength" to message.length,
                "parts" to parts.size,
                "subscriptionId" to subscriptionId,
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
    private fun isInService(): Boolean {
        // Airplane mode check requires no runtime permission.
        val isAirplaneMode = Settings.Global.getInt(
            context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
        if (isAirplaneMode) return false

        return try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
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

    // ── Default SMS app role ─────────────────────────────────────────────────

    /** True when this app currently holds the default-SMS-app role. */
    fun isDefaultSmsApp(): Boolean =
        Telephony.Sms.getDefaultSmsPackage(context) == context.packageName

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
    fun writeSentToProvider(address: String, body: String, timestamp: Long): Long {
        if (!isDefaultSmsApp()) return -1
        return try {
            val values = ContentValues().apply {
                put(Telephony.Sms.ADDRESS, address)
                put(Telephony.Sms.BODY, body)
                put(Telephony.Sms.DATE, timestamp)
                put(Telephony.Sms.READ, 1)
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
     * Get all available SIM cards (for dual-SIM support)
     */
    fun getAvailableSubscriptions(): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) {
            return emptyList()
        }

        return try {
            val subscriptionManager = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) 
                as? SubscriptionManager
            
            val subscriptions = subscriptionManager?.activeSubscriptionInfoList ?: emptyList()
            
            subscriptions.map { info: SubscriptionInfo ->
                mapOf(
                    "subscriptionId" to info.subscriptionId,
                    "displayName" to (info.displayName?.toString() ?: ""),
                    "carrierName" to (info.carrierName?.toString() ?: ""),
                    "slotIndex" to info.simSlotIndex
                )
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "Permission denied to access subscription info: ${e.message}")
            emptyList()
        } catch (e: Exception) {
            Log.e(TAG, "Error getting subscriptions: ${e.message}", e)
            emptyList()
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

                    if (phoneNumber == null || message == null) {
                        result.error("INVALID_ARGUMENTS", "Phone number and message are required", null)
                        return@setMethodCallHandler
                    }

                    coroutineScope.launch {
                        try {
                            val sendResult = sendSms(phoneNumber, message, subscriptionId)
                            
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
                
                "getAvailableSubscriptions" -> {
                    try {
                        val subscriptions = getAvailableSubscriptions()
                        result.success(subscriptions)
                    } catch (e: Exception) {
                        result.error("SUBSCRIPTION_ERROR", e.message, e.stackTraceToString())
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



