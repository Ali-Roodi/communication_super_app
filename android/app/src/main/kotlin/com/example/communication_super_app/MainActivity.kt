package com.example.communication_super_app

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import com.example.communication_super_app.call.CallHandler
import com.example.communication_super_app.calllog.CallLogSyncHandler
import com.example.communication_super_app.scheduled.ScheduledSmsChannel
import com.example.communication_super_app.scheduled.ScheduledSmsScheduler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var smsHandler: SmsHandler? = null
    private var callHandler: CallHandler? = null
    private var callLogSyncHandler: CallLogSyncHandler? = null

    /// Deep-link channel: SMS-notification taps carry a `threadId` extra.
    private var intentsChannel: MethodChannel? = null

    /// Pending result for an in-flight image pick (resolved in onActivityResult).
    private var pendingPickResult: MethodChannel.Result? = null

    companion object {
        /** Thread currently on screen in Flutter (null = none). Set over the
         *  intents channel; [SmsNotifier] suppresses notifications for it
         *  while the activity is resumed (Google Messages behavior). */
        @JvmStatic
        @Volatile
        var visibleThreadId: String? = null

        /** True between onResume and onPause — a "visible" thread only
         *  suppresses notifications while the app is actually foreground. */
        @JvmStatic
        @Volatile
        var isResumed = false

        private const val CHANNEL_SMS_METHOD = "com.example.communication_super_app/sms"
        private const val CHANNEL_SMS_EVENTS = "com.example.communication_super_app/sms_events"
        private const val CHANNEL_MEDIA = "com.example.communication_super_app/media"
        private const val CHANNEL_SCHEDULED = "com.example.communication_super_app/scheduled_sms"
        private const val CHANNEL_CALL_LOG = "com.example.communication_super_app/call_log"
        private const val CHANNEL_CALL_LOG_EVENTS = "com.example.communication_super_app/call_log_events"
        private const val CHANNEL_INTENTS = "com.example.communication_super_app/intents"
        private const val REQUEST_PICK_IMAGE = 9001
        private const val MAX_DIMEN = 512
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── SMS Handler (موجود) ────────────────────────────────────────
        smsHandler = SmsHandler(applicationContext, this)
        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_SMS_METHOD
        )
        smsHandler?.setupMethodChannel(methodChannel)
        val eventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_SMS_EVENTS
        )
        smsHandler?.setupEventChannel(eventChannel)

        // ── Call Handler (جدید) ────────────────────────────────────────
        // Activity ref: needed for the default-dialer role request dialog.
        callHandler = CallHandler(applicationContext, flutterEngine, this)

        // ── Call-log sync (تماس‌های اخیر — دوطرفه با گوشی) ───────────────
        callLogSyncHandler = CallLogSyncHandler(applicationContext)
        callLogSyncHandler?.setupMethodChannel(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_CALL_LOG)
        )
        callLogSyncHandler?.setupEventChannel(
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_CALL_LOG_EVENTS)
        )

        // ── Media picker (انتخاب عکس مخاطب) ─────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MEDIA)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickImage" -> pickImage(result)
                    else -> result.notImplemented()
                }
            }

        // ── Scheduled SMS (زمان‌بندی ارسال — تحویل پس‌زمینه) ─────────────
        // Published to ScheduledSmsChannel so the alarm receiver can hand the
        // delivery to Dart while the engine is alive (keeps the BLoCs in sync).
        val scheduledChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_SCHEDULED,
        )
        scheduledChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "reschedule" -> {
                    ScheduledSmsScheduler.reschedule(applicationContext)
                    result.success(true)
                }
                "cancel" -> {
                    ScheduledSmsScheduler.cancel(applicationContext)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        ScheduledSmsChannel.channel = scheduledChannel

        // ── Deep links (باز کردن گفتگو از اعلان) ─────────────────────────
        // Cold start: Dart asks for the launch intent's threadId once the UI
        // is up. Warm start (app alive, notification tapped): onNewIntent
        // pushes the threadId to Dart directly.
        intentsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_INTENTS,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialThreadId" -> {
                        val id = intent?.getStringExtra("threadId")
                        intent?.removeExtra("threadId")
                        result.success(id)
                    }
                    // Which conversation is on screen (null when none) — used
                    // to suppress notifications for the open chat.
                    "setVisibleThread" -> {
                        visibleThreadId = call.arguments as? String
                        result.success(true)
                    }
                    // Dismiss this thread's SMS notifications (user opened it).
                    "clearThreadNotifications" -> {
                        val threadId = call.arguments as? String
                        if (threadId != null) {
                            SmsNotifier.cancelThread(applicationContext, threadId)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra("threadId")?.let { threadId ->
            intent.removeExtra("threadId")
            intentsChannel?.invokeMethod("openThread", threadId)
        }
    }

    private fun pickImage(result: MethodChannel.Result) {
        // Only one pick at a time; reject a stale pending request.
        pendingPickResult?.success(null)
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = "image/*"
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        try {
            startActivityForResult(
                Intent.createChooser(intent, "انتخاب عکس"),
                REQUEST_PICK_IMAGE
            )
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("PICK_FAILED", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        // Default-SMS / default-dialer role dialog outcomes → resolve the
        // pending Flutter calls.
        if (smsHandler?.handleRoleActivityResult(requestCode) == true) return
        if (callHandler?.handleRoleActivityResult(requestCode) == true) return
        if (requestCode != REQUEST_PICK_IMAGE) return
        val result = pendingPickResult ?: return
        pendingPickResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        try {
            val bytes = decodeScaledJpeg(data.data!!)
            result.success(bytes)
        } catch (e: Exception) {
            result.error("DECODE_FAILED", e.message, null)
        }
    }

    /// Reads the picked image, downscales it to <= MAX_DIMEN, and returns JPEG bytes.
    private fun decodeScaledJpeg(uri: android.net.Uri): ByteArray? {
        val resolver = contentResolver
        // First pass: bounds only, to compute the sample size.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        val largest = maxOf(bounds.outWidth, bounds.outHeight)
        while (largest / sample > MAX_DIMEN * 2) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, opts)
        } ?: return null
        // Scale precisely to fit MAX_DIMEN on the longest edge.
        val scale = MAX_DIMEN.toFloat() / maxOf(decoded.width, decoded.height)
        val bitmap = if (scale < 1f) {
            Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * scale).toInt(),
                (decoded.height * scale).toInt(),
                true
            )
        } else {
            decoded
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
        return out.toByteArray()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        smsHandler?.registerReceiver()
    }

    override fun onResume() {
        super.onResume()
        isResumed = true
        smsHandler?.registerReceiver()
    }

    override fun onPause() {
        isResumed = false
        super.onPause()
    }

    override fun onDestroy() {
        smsHandler?.dispose()
        smsHandler = null
        callHandler = null
        callLogSyncHandler?.dispose()
        callLogSyncHandler = null
        // The engine is going away: the alarm receiver must go back to delivering
        // scheduled messages natively.
        ScheduledSmsChannel.channel = null
        super.onDestroy()
    }
}
