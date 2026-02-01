package com.example.communication_super_app

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var smsHandler: SmsHandler? = null
    
    companion object {
        private const val CHANNEL_SMS_METHOD = "com.example.communication_super_app/sms"
        private const val CHANNEL_SMS_EVENTS = "com.example.communication_super_app/sms_events"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Initialize SMS handler
        smsHandler = SmsHandler(applicationContext, this)
        
        // Set up MethodChannel for SMS operations
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SMS_METHOD)
        smsHandler?.setupMethodChannel(methodChannel)
        
        // Set up EventChannel for SMS reception
        val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SMS_EVENTS)
        smsHandler?.setupEventChannel(eventChannel)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Register SMS receiver when activity is created
        smsHandler?.registerReceiver()
    }

    override fun onDestroy() {
        // Clean up resources
        smsHandler?.dispose()
        smsHandler = null
        super.onDestroy()
    }
    
    override fun onResume() {
        super.onResume()
        // Re-register receiver if needed
        smsHandler?.registerReceiver()
    }
}
