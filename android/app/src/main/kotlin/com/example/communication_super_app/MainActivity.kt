package com.example.communication_super_app

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import com.example.communication_super_app.call.CallHandler
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

    /// Pending result for an in-flight image pick (resolved in onActivityResult).
    private var pendingPickResult: MethodChannel.Result? = null

    companion object {
        private const val CHANNEL_SMS_METHOD = "com.example.communication_super_app/sms"
        private const val CHANNEL_SMS_EVENTS = "com.example.communication_super_app/sms_events"
        private const val CHANNEL_MEDIA = "com.example.communication_super_app/media"
        private const val CHANNEL_SCHEDULED = "com.example.communication_super_app/scheduled_sms"
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
        callHandler = CallHandler(applicationContext, flutterEngine)

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
        smsHandler?.registerReceiver()
    }

    override fun onDestroy() {
        smsHandler?.dispose()
        smsHandler = null
        callHandler = null
        // The engine is going away: the alarm receiver must go back to delivering
        // scheduled messages natively.
        ScheduledSmsChannel.channel = null
        super.onDestroy()
    }
}
