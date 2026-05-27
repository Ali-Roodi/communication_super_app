package com.example.communication_super_app

import android.os.Bundle
import com.example.communication_super_app.call.CallHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var smsHandler: SmsHandler? = null
    private var callHandler: CallHandler? = null

    companion object {
        private const val CHANNEL_SMS_METHOD = "com.example.communication_super_app/sms"
        private const val CHANNEL_SMS_EVENTS = "com.example.communication_super_app/sms_events"
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
        super.onDestroy()
    }
}
