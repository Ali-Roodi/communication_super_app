package com.example.communication_super_app

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import com.example.communication_super_app.call.CallEventStreamHandler
import com.example.communication_super_app.call.CallHandler
import com.example.communication_super_app.call.CallInCallService
import com.example.communication_super_app.calllog.CallLogSyncHandler
import com.example.communication_super_app.contacts.ContactExtrasHandler
import com.example.communication_super_app.contacts.ContactGroupsHandler
import com.example.communication_super_app.contacts.ContactLinkHandler
import com.example.communication_super_app.contacts.SimContactsHandler
import com.example.communication_super_app.media.PhotoHandler
import com.example.communication_super_app.scheduled.ScheduledSmsChannel
import com.example.communication_super_app.scheduled.ScheduledSmsScheduler
import com.example.communication_super_app.sim.SimHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var smsHandler: SmsHandler? = null
    private var callHandler: CallHandler? = null
    private var callLogSyncHandler: CallLogSyncHandler? = null
    private var contactExtrasHandler: ContactExtrasHandler? = null
    private var contactLinkHandler: ContactLinkHandler? = null
    private var contactGroupsHandler: ContactGroupsHandler? = null
    private var simHandler: SimHandler? = null
    private var simContactsHandler: SimContactsHandler? = null
    private var locationHandler: LocationHandler? = null

    /// Deep-link channel: SMS-notification taps carry a `threadId` extra.
    private var intentsChannel: MethodChannel? = null

    /// Contact photos: gallery / camera pick plus the crop, rotate and resize
    /// the editor asks for. Owns its own activity-result plumbing.
    private var photoHandler: PhotoHandler? = null

    /**
     * Whether this activity is currently asking to be shown over the keyguard.
     *
     * Only a live call ever sets it, and only clearing it may hand the screen
     * back to the lock screen — see [showOverLockScreen].
     */
    private var overLockScreen = false

    companion object {
        /** The live activity, so the in-call service can flip its lock-screen
         *  window flags. Cleared in onDestroy. */
        @JvmStatic
        @Volatile
        var instance: MainActivity? = null

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

        // ── Per-contact settings (آهنگ زنگ، پست صوتی، هم‌رسانی، برنامه‌های متصل)
        contactExtrasHandler = ContactExtrasHandler(applicationContext, this)
        contactExtrasHandler?.setup(
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                ContactExtrasHandler.CHANNEL,
            )
        )

        // ── Linking duplicate contacts (ادغام) ──────────────────────────
        // AggregationExceptions, which flutter_contacts does not expose — see
        // ContactLinkHandler for why this is not "write one and delete the
        // rest".
        contactLinkHandler = ContactLinkHandler(applicationContext)
        contactLinkHandler?.setup(
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                ContactLinkHandler.CHANNEL,
            )
        )

        // ── Contact labels (برچسب‌ها) ───────────────────────────────────
        // Groups belong to ACCOUNTS, and flutter_contacts writes them without
        // one — see ContactGroupsHandler for why a label made through the
        // plugin could never hold anybody.
        contactGroupsHandler = ContactGroupsHandler(applicationContext)
        contactGroupsHandler?.setup(
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                ContactGroupsHandler.CHANNEL,
            )
        )

        // ── SIM roster (دو سیم‌کارته) ───────────────────────────────────
        // Method channel for the one-shot reads, event channel for the live
        // roster — a SIM inserted while the app runs must change the composer
        // chip, the dial button and the SIM address book without a restart.
        simHandler = SimHandler(applicationContext)
        simHandler?.setupMethodChannel(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SimHandler.METHOD_CHANNEL)
        )
        simHandler?.setupEventChannel(
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, SimHandler.EVENT_CHANNEL)
        )

        // ── SIM address book (content://icc/adn) ────────────────────────
        // NOT in ContactsContract — see SimContactsHandler.
        simContactsHandler = SimContactsHandler(applicationContext)
        simContactsHandler?.setup(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SimContactsHandler.CHANNEL)
        )

        // ── Location («موقعیت» در پیوست پیام) ───────────────────────────
        // One coordinate pair, on one tap, inserted as text. Platform
        // LocationManager rather than a plugin — see LocationHandler.
        locationHandler = LocationHandler(applicationContext)
        locationHandler?.setup(
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                LocationHandler.CHANNEL,
            )
        )

        // ── Contact photo (دوربین / گالری + برش و چرخش) ──────────────────
        photoHandler = PhotoHandler(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MEDIA)
            .setMethodCallHandler { call, result ->
                if (photoHandler?.handle(call, result) != true) result.notImplemented()
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
                    "getInitialAction" -> result.success(consumeLaunchAction(intent))
                    // Which conversation is on screen (null when none) — used
                    // to suppress notifications for the open chat.
                    "setVisibleThread" -> {
                        visibleThreadId = call.arguments as? String
                        result.success(true)
                    }
                    // «اخیر» came on screen — the missed-call notifications
                    // point at the list the user is now looking at.
                    "clearMissedCallNotifications" -> {
                        CallInCallService.clearMissedCallNotifications(
                            applicationContext,
                        )
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
        consumeLaunchAction(intent)?.let {
            intentsChannel?.invokeMethod("openAction", it)
        }
    }

    /**
     * What the launching intent is asking the app to open, or null.
     *
     * Three kinds, and only the first one existed before:
     *
     * - `thread` — an SMS notification tap (`threadId` extra).
     * - `dial` — `ACTION_DIAL` / `ACTION_VIEW` on a `tel:` URI. This is what
     *   «Call» on a selected number in a browser or another app produces, and
     *   holding ROLE_DIALER means it is delivered *here*: the manifest declared
     *   the filter (the role requires it) while nothing read the intent, so the
     *   app opened on whatever tab it felt like and the number was lost.
     * - `sms` — `ACTION_SENDTO`/`ACTION_VIEW` on `sms:`/`smsto:`/`mms:`/
     *   `mmsto:`, or a plain-text `ACTION_SEND` share. Same story on the SMS
     *   side of the two roles.
     *
     * **Consuming**: whatever was read is stripped from the intent, because the
     * activity keeps it. Without that, every later resume would re-open the
     * same conversation or keypad on top of whatever the user had navigated to.
     */
    private fun consumeLaunchAction(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null

        // «تماس در جریان» tapped: the activity is coming forward, but the call
        // route may have been minimized — bringing the window up alone would
        // land the user on whatever they left the call to look at. This is
        // pushed straight onto the call event stream rather than through the
        // launch-action map, because CallUiCoordinator sits above the auth flow
        // and must not wait for MainNavigation (which is behind the app lock).
        if (intent.getBooleanExtra(CallInCallService.EXTRA_RETURN_TO_CALL, false)) {
            intent.removeExtra(CallInCallService.EXTRA_RETURN_TO_CALL)
            CallEventStreamHandler.sendRaw(mapOf("event" to "SHOW_CALL_UI"))
        }

        intent.getStringExtra("threadId")?.let { threadId ->
            intent.removeExtra("threadId")
            if (threadId.isNotEmpty()) {
                return mapOf("type" to "thread", "threadId" to threadId)
            }
        }

        val data = intent.data
        val action = intent.action
        // getSchemeSpecificPart, never the path: `tel:*100%23` decodes back to
        // the literal «*100#» here, which is the whole point of building the
        // URI with Uri.fromParts (see CallHandler.makeCall).
        val target = data?.schemeSpecificPart?.trim().orEmpty()

        when (data?.scheme?.lowercase()) {
            "tel" -> if (action == Intent.ACTION_DIAL || action == Intent.ACTION_VIEW) {
                intent.data = null
                return mapOf("type" to "dial", "number" to target)
            }
            "sms", "smsto", "mms", "mmsto" -> {
                intent.data = null
                // «//» and a trailing «?body=…» are both legal in these URIs.
                // The query is pulled out by hand: `sms:0912…?body=…` is an
                // *opaque* URI and `Uri.getQueryParameter` throws on those.
                val number = target.substringBefore('?').trimStart('/')
                val query = target.substringAfter('?', "")
                val bodyFromUri = query
                    .split('&')
                    .firstOrNull { it.startsWith("body=") }
                    ?.removePrefix("body=")
                    ?.let { runCatching { Uri.decode(it) }.getOrNull() }
                val body = intent.getStringExtra("sms_body")
                    ?: bodyFromUri
                    ?: intent.getStringExtra(Intent.EXTRA_TEXT)
                return mapOf(
                    "type" to "sms",
                    "number" to number,
                    "body" to body,
                )
            }
        }

        // Share-to-SMS with no recipient: the app picks who to send it to.
        if (action == Intent.ACTION_SEND && intent.type == "text/plain") {
            val body = intent.getStringExtra(Intent.EXTRA_TEXT)
            intent.removeExtra(Intent.EXTRA_TEXT)
            if (!body.isNullOrEmpty()) {
                return mapOf("type" to "sms", "number" to "", "body" to body)
            }
        }
        return null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        // Default-SMS / default-dialer role dialog outcomes → resolve the
        // pending Flutter calls.
        if (smsHandler?.handleRoleActivityResult(requestCode) == true) return
        if (callHandler?.handleRoleActivityResult(requestCode) == true) return
        if (contactExtrasHandler?.handleActivityResult(requestCode, data) == true) return
        photoHandler?.handleActivityResult(requestCode, resultCode, data)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        // Before the first call, so «تماس ورودی» exists in the system settings
        // and the app can tell "switched off by the user" from "never created".
        CallInCallService.ensureChannels(applicationContext)
        smsHandler?.registerReceiver()
        // The full-screen intent of an incoming call cold-starts this activity;
        // without the flags below it lands *behind* the keyguard and the user
        // sees a black screen with the phone still ringing.
        syncLockScreenVisibility()
    }

    // The incoming-call notification is tied to start/stop, NOT resume/pause.
    // Over a keyguard this activity is paused and resumed repeatedly while
    // staying perfectly visible, and re-posting on every pause put the card
    // back on the lock screen next to the call screen. onStop is the only
    // signal that the call UI really went away.
    override fun onStart() {
        super.onStart()
        android.util.Log.d("CallUi", "MainActivity.onStart")
        CallInCallService.instance?.onCallUiVisible(true)
    }

    override fun onStop() {
        android.util.Log.d("CallUi", "MainActivity.onStop")
        // Left the call screen with the phone still ringing — put the
        // notification back so the call stays reachable.
        CallInCallService.instance?.onCallUiVisible(false)
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        isResumed = true
        smsHandler?.registerReceiver()
        syncLockScreenVisibility()
        // Re-assert: a keyguard-driven resume can land after the card was
        // posted by an onStop that the call outlived.
        CallInCallService.instance?.onCallUiVisible(true)
    }

    override fun onPause() {
        isResumed = false
        super.onPause()
    }

    /**
     * Turns "show over the lock screen" on while a call exists and off again
     * once it is gone.
     *
     * It is deliberately NOT a manifest attribute: the app holds a PIN/pattern
     * lock, so it must sit over the keyguard only for calls, never for the
     * inbox. The screen is also woken and kept on — a ringing call that leaves
     * the display asleep is unanswerable.
     */
    fun syncLockScreenVisibility() {
        showOverLockScreen(CallInCallService.hasLiveCall())
    }

    fun showOverLockScreen(show: Boolean) {
        runOnUiThread {
            val keyguard =
                getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            // Call ended while the phone is still locked: hand the screen back
            // to the keyguard *first*. Only clearing the flags leaves this
            // activity on top for a frame or two, which showed a flash of the
            // app's normal UI (inbox/dialer) over the lock screen.
            //
            // GATED ON [overLockScreen], and that gate is the whole point: this
            // runs from `onCreate`/`onResume` too, and waking a locked phone
            // resumes the foreground activity *behind* the keyguard. Without
            // the gate, every screen-on with this app in front hit
            // `moveTaskToBack` — so unlocking the phone landed on the home
            // screen and the app looked as if it had closed itself, losing
            // whatever the user was reading. Only a call that actually put
            // this activity over the keyguard may hand the screen back.
            if (!show && overLockScreen && keyguard.isKeyguardLocked) {
                moveTaskToBack(true)
            }
            overLockScreen = show
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(show)
                setTurnScreenOn(show)
            }
            // Pre-27 equivalents (deprecated after, so only set there).
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) {
                val legacy = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                if (show) window.addFlags(legacy) else window.clearFlags(legacy)
            }
            // KEEP_SCREEN_ON only while a call is RINGING — a call the user
            // cannot see is a call they cannot answer. It must NOT span the
            // whole call: it holds a screen-bright wake lock, so the display
            // stayed lit against the ear for the entire conversation and «پایان»
            // / «بی‌صدا» sat exactly where a cheek lands. Once answered the
            // proximity sensor owns the display (see ProximityGate), which is
            // also what Google Phone does.
            val keepOn = show && CallInCallService.hasRingingCall()
            val keepFlag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            if (keepOn) window.addFlags(keepFlag) else window.clearFlags(keepFlag)
            // An *insecure* keyguard (swipe only) still covers the window, so
            // ask for it to be taken down. A secure one is left alone: the call
            // UI is meant to show over it without unlocking the phone.
            if (show) {
                val keyguard =
                    getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                if (!keyguard.isKeyguardSecure && keyguard.isKeyguardLocked) {
                    keyguard.requestDismissKeyguard(this, null)
                }
            }
        }
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        smsHandler?.dispose()
        smsHandler = null
        callHandler = null
        callLogSyncHandler?.dispose()
        callLogSyncHandler = null
        contactExtrasHandler = null
        simHandler?.dispose()
        simHandler = null
        simContactsHandler = null
        locationHandler = null
        // The engine is going away: the alarm receiver must go back to delivering
        // scheduled messages natively.
        ScheduledSmsChannel.channel = null
        super.onDestroy()
    }
}
