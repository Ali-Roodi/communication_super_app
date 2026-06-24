# پلن اجرایی MVP — قاسم
### قدم‌به‌قدم · بر اساس پروژه موجود · ظاهر Google Phone

> **پیش‌فرض:** پروژه موجود کار می‌کند. این سند دقیقاً چه فایلی را عوض کنید، چه فایلی را بسازید، و کد دقیق هر مرحله را مشخص می‌کند.  
> **ترتیب اجرا اجباری است** — هر مرحله روی مرحله قبل بنا می‌شود.

---

## نقشه کلی مراحل

```
مرحله 0 — آماده‌سازی پایه          (~30 دقیقه)
مرحله 1 — رفع باگ‌های فوری         (~1 ساعت)
مرحله 2 — تم و رنگ Google Phone    (~2 ساعت)
مرحله 3 — تماس بومی Kotlin         (~4 ساعت)
مرحله 4 — صفحه‌های تماس Flutter    (~3 ساعت)
مرحله 5 — UI شبیه Google Phone     (~6 ساعت)
مرحله 6 — Settings Feature         (~2 ساعت)
مرحله 7 — رفع باگ نرمال‌سازی شماره (~1 ساعت)
مرحله 8 — تست نهایی و polish       (~2 ساعت)
```

---

## مرحله 0 — آماده‌سازی پایه

### 0-1. به‌روزرسانی `pubspec.yaml`

فایل موجود را باز کنید و بخش `dependencies` را به این شکل به‌روز کنید:

```yaml
dependencies:
  flutter:
    sdk: flutter

  # State Management (موجود — نگه دارید)
  flutter_bloc: ^8.1.6
  equatable: ^2.0.5

  # Database (موجود — نگه دارید)
  sqflite: ^2.3.3
  path: ^1.9.0

  # Storage (موجود — نگه دارید)
  flutter_secure_storage: ^9.2.2

  # ✦ جدید — اضافه کنید
  shared_preferences: ^2.3.2

  # SMS (موجود — نگه دارید)
  telephony: ^0.2.0

  # Permissions (موجود — نگه دارید)
  permission_handler: ^11.3.1

  # Notifications (موجود — نگه دارید)
  flutter_local_notifications: ^17.2.2

  # ✦ جدید — اضافه کنید
  go_router: ^14.2.7
  shimmer: ^3.0.0
  fast_contacts: ^3.0.1
  shamsi_date: ^1.1.2
  intl: ^0.19.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  # ✦ جدید
  bloc_test: ^9.1.7
  mocktail: ^1.0.4
```

سپس اجرا کنید:
```bash
flutter pub get
```

---

### 0-2. ساختار پوشه‌های جدید

این پوشه‌ها را بسازید (فایل‌شان را در مراحل بعد می‌سازیم):

```bash
mkdir -p lib/core/theme
mkdir -p lib/core/router
mkdir -p lib/features/settings/bloc
mkdir -p lib/features/settings/screens
mkdir -p lib/features/dialer/services
mkdir -p lib/features/dialer/screens/widgets
mkdir -p android/app/src/main/kotlin/com/example/communication_super_app/call
```

---

## مرحله 1 — رفع باگ‌های فوری

### 1-1. باگ: `_imported` static flag (B6)

**فایل:** `lib/features/messages/services/sms_service.dart`

پیدا کنید:
```dart
static bool _imported = false;
```

جایگزین کنید با:
```dart
// حذف static flag — از SharedPreferences استفاده می‌کنیم
```

در متد `importDeviceMessages` پیدا کنید:
```dart
if (_imported) return;
_imported = true;
```

جایگزین کنید با:
```dart
final prefs = await SharedPreferences.getInstance();
final alreadyImported = prefs.getBool('sms_imported_v1') ?? false;
if (alreadyImported) return;
await prefs.setBool('sms_imported_v1', true);
```

ایمپورت را بالای فایل اضافه کنید:
```dart
import 'package:shared_preferences/shared_preferences.dart';
```

---

### 1-2. باگ: مجوز POST_NOTIFICATIONS برای Android 13+ (B4)

**فایل:** `lib/core/widgets/permission_gate.dart`

پیدا کنید لیست permissions را و اضافه کنید:
```dart
final permissions = [
  Permission.sms,
  Permission.phone,
  Permission.contacts,
  Permission.microphone,
  // ✦ اضافه کنید:
  if (Platform.isAndroid &&
      (await DeviceInfoPlugin().androidInfo).version.sdkInt >= 33)
    Permission.notification,
];
```

ایمپورت‌ها:
```dart
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
```

> **نکته:** `device_info_plus` را هم به pubspec.yaml اضافه کنید: `device_info_plus: ^10.1.2`

---

### 1-3. باگ: تماس بومی موجود نیست — Placeholder موقت (B3)

تا مرحله 3 تمام شود، در `lib/features/dialer/screens/dialer_screen.dart` دکمه تماس را این‌طور محافظت کنید:

```dart
// پیدا کنید دکمه Call را و این check را اضافه کنید:
onCallPressed: () {
  if (dialedNumber.isEmpty) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('در حال راه‌اندازی سرویس تماس...')),
  );
  // TODO: در مرحله 3 جایگزین می‌شود
},
```

---

## مرحله 2 — تم و رنگ Google Phone

### 2-1. ساخت `lib/core/theme/app_colors.dart`

```dart
import 'package:flutter/material.dart';

abstract class AppColors {
  // ── Google Phone Brand Colors ──────────────────────────
  static const Color googleBlue      = Color(0xFF1A73E8);
  static const Color googleBlueDark  = Color(0xFF8AB4F8);

  // ── Call Actions ───────────────────────────────────────
  static const Color callAnswerGreen = Color(0xFF34A853);
  static const Color callRejectRed   = Color(0xFFEA4335);
  static const Color callHoldOrange  = Color(0xFFFBBC04);
  static const Color missedCallRed   = Color(0xFFEA4335);

  // ── Light Theme Surfaces ───────────────────────────────
  static const Color surfaceLight       = Color(0xFFFFFFFF);
  static const Color backgroundLight    = Color(0xFFF8F9FA);
  static const Color cardLight          = Color(0xFFFFFFFF);
  static const Color dividerLight       = Color(0xFFE0E0E0);
  static const Color onSurfaceLight     = Color(0xFF202124);
  static const Color onSurfaceLightDim  = Color(0xFF5F6368);
  static const Color chipLight          = Color(0xFFE8F0FE);

  // ── Dark Theme Surfaces ────────────────────────────────
  static const Color surfaceDark        = Color(0xFF202124);
  static const Color backgroundDark     = Color(0xFF121212);
  static const Color cardDark           = Color(0xFF2D2E31);
  static const Color dividerDark        = Color(0xFF3C3C3C);
  static const Color onSurfaceDark      = Color(0xFFE8EAED);
  static const Color onSurfaceDarkDim   = Color(0xFF9AA0A6);

  // ── Dialer Specific ────────────────────────────────────
  static const Color dialerKeyLight     = Color(0xFFF1F3F4);
  static const Color dialerKeyDark      = Color(0xFF3C4043);
  static const Color dialerKeyTextLight = Color(0xFF202124);
  static const Color dialerKeyTextDark  = Color(0xFFE8EAED);
}
```

---

### 2-2. ساخت `lib/core/theme/app_theme.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_colors.dart';

abstract class AppTheme {
  static const String _fontFamily = 'Vazirmatn'; // اگر ندارید: حذف کنید

  // ── Light Theme ────────────────────────────────────────
  static ThemeData get light => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.googleBlue,
      brightness: Brightness.light,
      primary: AppColors.googleBlue,
      surface: AppColors.surfaceLight,
    ),
    scaffoldBackgroundColor: AppColors.backgroundLight,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surfaceLight,
      foregroundColor: AppColors.onSurfaceLight,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(
        color: AppColors.onSurfaceLight,
        fontSize: 22,
        fontWeight: FontWeight.w400,
        fontFamily: _fontFamily,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.surfaceLight,
      selectedItemColor: AppColors.googleBlue,
      unselectedItemColor: AppColors.onSurfaceLightDim,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.callAnswerGreen,
      foregroundColor: Colors.white,
      elevation: 4,
    ),
    cardTheme: CardTheme(
      color: AppColors.cardLight,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.dividerLight,
      thickness: 0.5,
      space: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.backgroundLight,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    textTheme: _buildTextTheme(AppColors.onSurfaceLight, AppColors.onSurfaceLightDim),
  );

  // ── Dark Theme ─────────────────────────────────────────
  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.googleBlue,
      brightness: Brightness.dark,
      primary: AppColors.googleBlueDark,
      surface: AppColors.surfaceDark,
    ),
    scaffoldBackgroundColor: AppColors.backgroundDark,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surfaceDark,
      foregroundColor: AppColors.onSurfaceDark,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      titleTextStyle: TextStyle(
        color: AppColors.onSurfaceDark,
        fontSize: 22,
        fontWeight: FontWeight.w400,
        fontFamily: _fontFamily,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.surfaceDark,
      selectedItemColor: AppColors.googleBlueDark,
      unselectedItemColor: AppColors.onSurfaceDarkDim,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.callAnswerGreen,
      foregroundColor: Colors.white,
      elevation: 4,
    ),
    cardTheme: CardTheme(
      color: AppColors.cardDark,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.dividerDark,
      thickness: 0.5,
      space: 0,
    ),
    scaffoldBackgroundColor: AppColors.backgroundDark,
    textTheme: _buildTextTheme(AppColors.onSurfaceDark, AppColors.onSurfaceDarkDim),
  );

  static TextTheme _buildTextTheme(Color primary, Color secondary) => TextTheme(
    displayLarge: TextStyle(color: primary, fontFamily: _fontFamily),
    titleLarge:   TextStyle(color: primary, fontFamily: _fontFamily, fontWeight: FontWeight.w500),
    titleMedium:  TextStyle(color: primary, fontFamily: _fontFamily),
    bodyLarge:    TextStyle(color: primary, fontFamily: _fontFamily),
    bodyMedium:   TextStyle(color: secondary, fontFamily: _fontFamily),
    bodySmall:    TextStyle(color: secondary, fontFamily: _fontFamily, fontSize: 12),
    labelSmall:   TextStyle(color: secondary, fontFamily: _fontFamily),
  );
}
```

---

### 2-3. ساخت `lib/core/theme/theme_bloc.dart`

```dart
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Events ────────────────────────────────────────────────
abstract class ThemeEvent {}
class LoadTheme extends ThemeEvent {}
class ToggleTheme extends ThemeEvent {}
class SetDarkTheme extends ThemeEvent {}
class SetLightTheme extends ThemeEvent {}

// ── States ────────────────────────────────────────────────
enum AppThemeMode { light, dark }

class ThemeState {
  final AppThemeMode mode;
  const ThemeState(this.mode);
  bool get isDark => mode == AppThemeMode.dark;
}

// ── Bloc ──────────────────────────────────────────────────
class ThemeBloc extends Bloc<ThemeEvent, ThemeState> {
  static const _key = 'theme_mode';

  ThemeBloc() : super(const ThemeState(AppThemeMode.light)) {
    on<LoadTheme>(_onLoad);
    on<ToggleTheme>(_onToggle);
    on<SetDarkTheme>((_, emit) => _save(emit, AppThemeMode.dark));
    on<SetLightTheme>((_, emit) => _save(emit, AppThemeMode.light));
  }

  Future<void> _onLoad(LoadTheme event, Emitter<ThemeState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_key) ?? false;
    emit(ThemeState(isDark ? AppThemeMode.dark : AppThemeMode.light));
  }

  Future<void> _onToggle(ToggleTheme event, Emitter<ThemeState> emit) async {
    final next = state.isDark ? AppThemeMode.light : AppThemeMode.dark;
    await _save(emit, next);
  }

  Future<void> _save(Emitter<ThemeState> emit, AppThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, mode == AppThemeMode.dark);
    emit(ThemeState(mode));
  }
}
```

---

### 2-4. به‌روزرسانی `main.dart`

پیدا کنید `MaterialApp` را و این‌طور عوض کنید:

```dart
import 'core/theme/app_theme.dart';
import 'core/theme/theme_bloc.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GhasemApp());
}

class GhasemApp extends StatelessWidget {
  const GhasemApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ThemeBloc()..add(LoadTheme())),
        // ... سایر BloC‌های موجود شما
        ...AppBlocProviders.providers,
      ],
      child: BlocBuilder<ThemeBloc, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            title: 'قاسم',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: themeState.isDark ? ThemeMode.dark : ThemeMode.light,
            // home یا initialRoute موجود خود را نگه دارید
            home: const AppLockWrapper(),
          );
        },
      ),
    );
  }
}
```

---

## مرحله 3 — تماس بومی Kotlin

### 3-1. ساخت `CallEvent.kt`

**فایل:** `android/app/src/main/kotlin/com/example/communication_super_app/call/CallEvent.kt`

```kotlin
package com.example.communication_super_app.call

enum class CallEvent {
    INCOMING,
    RINGING,
    ACTIVE,
    ON_HOLD,
    DISCONNECTED,
    CALL_FAILED
}
```

---

### 3-2. ساخت `CallEventStreamHandler.kt`

**فایل:** `android/.../call/CallEventStreamHandler.kt`

```kotlin
package com.example.communication_super_app.call

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object CallEventStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun sendEvent(event: CallEvent, data: Map<String, Any?> = emptyMap()) {
        Handler(Looper.getMainLooper()).post {
            val payload = data.toMutableMap()
            payload["event"] = event.name
            eventSink?.success(payload)
        }
    }
}
```

---

### 3-3. ساخت `CallConnection.kt`

**فایل:** `android/.../call/CallConnection.kt`

```kotlin
package com.example.communication_super_app.call

import android.telecom.Connection
import android.telecom.DisconnectCause

class CallConnection : Connection() {

    companion object {
        var instance: CallConnection? = null
    }

    init {
        instance = this
        audioModeIsVoip = false
        connectionCapabilities = CAPABILITY_HOLD or
                CAPABILITY_SUPPORT_HOLD or
                CAPABILITY_MUTE
    }

    override fun onAnswer() {
        setActive()
        CallEventStreamHandler.sendEvent(CallEvent.ACTIVE)
    }

    override fun onReject() {
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
        instance = null
        CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED)
    }

    override fun onDisconnect() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        instance = null
        CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED)
    }

    override fun onHold() {
        setOnHold()
        CallEventStreamHandler.sendEvent(CallEvent.ON_HOLD)
    }

    override fun onUnhold() {
        setActive()
        CallEventStreamHandler.sendEvent(CallEvent.ACTIVE)
    }

    override fun onShowIncomingCallUi() {
        // Flutter side صفحه incoming call را نشان می‌دهد
    }
}
```

---

### 3-4. ساخت `CallConnectionService.kt`

**فایل:** `android/.../call/CallConnectionService.kt`

```kotlin
package com.example.communication_super_app.call

import android.net.Uri
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

class CallConnectionService : ConnectionService() {

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val connection = CallConnection()
        connection.setDialing()
        connection.address = request.address

        // شماره تلفن را به Flutter بفرستید
        val phone = request.address?.schemeSpecificPart ?: ""
        CallEventStreamHandler.sendEvent(
            CallEvent.RINGING,
            mapOf("phone" to phone, "direction" to "outgoing")
        )
        return connection
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val connection = CallConnection()
        connection.setRinging()
        connection.address = request.address

        val phone = request.extras
            ?.getString(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS) ?: ""
        CallEventStreamHandler.sendEvent(
            CallEvent.INCOMING,
            mapOf("phone" to phone, "direction" to "incoming")
        )
        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ) {
        CallEventStreamHandler.sendEvent(CallEvent.CALL_FAILED)
    }
}
```

---

### 3-5. ساخت `CallHandler.kt`

**فایل:** `android/.../call/CallHandler.kt`

```kotlin
package com.example.communication_super_app.call

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class CallHandler(
    private val context: Context,
    flutterEngine: FlutterEngine
) {
    companion object {
        const val METHOD_CHANNEL = "com.example.communication_super_app/call"
        const val EVENT_CHANNEL  = "com.example.communication_super_app/call_events"
        private const val TAG = "CallHandler"
    }

    private val telecomManager by lazy {
        context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
    }
    private val audioManager by lazy {
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    init {
        // Method Channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "makeCall"       -> makeCall(call.argument<String>("phone") ?: "", result)
                    "endCall"        -> { endCall(); result.success(null) }
                    "answerCall"     -> { answerCall(); result.success(null) }
                    "rejectCall"     -> { rejectCall(); result.success(null) }
                    "holdCall"       -> { holdCall(call.argument<Boolean>("hold") ?: true); result.success(null) }
                    "muteCall"       -> { muteCall(call.argument<Boolean>("muted") ?: false); result.success(null) }
                    "setSpeakerphone"-> { setSpeakerphone(call.argument<Boolean>("on") ?: false); result.success(null) }
                    "sendDtmf"       -> { sendDtmf(call.argument<String>("digit") ?: ""); result.success(null) }
                    "isInCall"       -> result.success(CallConnection.instance != null)
                    else             -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Security: ${e.message}")
                result.error("PERMISSION_DENIED", e.message, null)
            } catch (e: Exception) {
                Log.e(TAG, "Error: ${e.message}")
                result.error("CALL_ERROR", e.message, null)
            }
        }

        // Event Channel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(CallEventStreamHandler)
    }

    private fun makeCall(phone: String, result: MethodChannel.Result) {
        val cleanPhone = phone.replace(Regex("[^+0-9]"), "")
        if (cleanPhone.isEmpty()) {
            result.error("INVALID_NUMBER", "شماره تلفن معتبر نیست", null)
            return
        }
        val uri = Uri.fromParts("tel", cleanPhone, null)
        val extras = Bundle()
        telecomManager.placeCall(uri, extras)
        result.success(null)
    }

    private fun endCall() {
        CallConnection.instance?.onDisconnect()
            ?: run {
                // Android P+: از TelecomManager استفاده کنید
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                    telecomManager.endCall()
                }
            }
    }

    private fun answerCall() {
        CallConnection.instance?.onAnswer()
    }

    private fun rejectCall() {
        CallConnection.instance?.onReject()
    }

    private fun holdCall(hold: Boolean) {
        if (hold) CallConnection.instance?.onHold()
        else CallConnection.instance?.onUnhold()
    }

    private fun muteCall(muted: Boolean) {
        audioManager.isMicrophoneMute = muted
    }

    private fun setSpeakerphone(on: Boolean) {
        audioManager.isSpeakerphoneOn = on
        audioManager.mode = if (on) AudioManager.MODE_NORMAL else AudioManager.MODE_IN_CALL
    }

    private fun sendDtmf(digit: String) {
        if (digit.isNotEmpty()) {
            CallConnection.instance?.playDtmfTone(digit[0])
        }
    }
}
```

---

### 3-6. به‌روزرسانی `MainActivity.kt`

پیدا کنید `MainActivity` را و این‌طور اضافه کنید:

```kotlin
import com.example.communication_super_app.call.CallHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private lateinit var callHandler: CallHandler

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // SMS handler موجود شما — نگه دارید
        // SmsHandler(this, flutterEngine)

        // ✦ جدید: Call handler
        callHandler = CallHandler(this, flutterEngine)
    }
}
```

---

### 3-7. به‌روزرسانی `AndroidManifest.xml`

داخل `<manifest>` اضافه کنید:

```xml
<!-- مجوزهای تماس — اگر ندارید اضافه کنید -->
<uses-permission android:name="android.permission.CALL_PHONE" />
<uses-permission android:name="android.permission.READ_CALL_LOG" />
<uses-permission android:name="android.permission.WRITE_CALL_LOG" />
<uses-permission android:name="android.permission.READ_PHONE_STATE" />
<uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.PROCESS_OUTGOING_CALLS" />
```

داخل `<application>` اضافه کنید:

```xml
<!-- CallConnectionService -->
<service
    android:name=".call.CallConnectionService"
    android:permission="android.permission.BIND_TELECOM_CONNECTION_SERVICE"
    android:exported="true">
    <intent-filter>
        <action android:name="android.telecom.ConnectionService" />
    </intent-filter>
</service>
```

---

### 3-8. ساخت `lib/features/dialer/services/native_call_service.dart`

```dart
import 'dart:async';
import 'package:flutter/services.dart';

enum CallEvent { incoming, ringing, active, onHold, disconnected, callFailed }

class CallInfo {
  final CallEvent event;
  final String phone;
  final String direction; // 'incoming' | 'outgoing'

  const CallInfo({
    required this.event,
    this.phone = '',
    this.direction = 'outgoing',
  });
}

class NativeCallService {
  NativeCallService._();
  static final NativeCallService instance = NativeCallService._();

  static const _method = MethodChannel(
    'com.example.communication_super_app/call',
  );
  static const _events = EventChannel(
    'com.example.communication_super_app/call_events',
  );

  Stream<CallInfo>? _stream;

  Stream<CallInfo> get callEvents {
    _stream ??= _events.receiveBroadcastStream().map((raw) {
      final map = Map<String, dynamic>.from(raw as Map);
      final event = CallEvent.values.byName(
        (map['event'] as String).toLowerCase(),
      );
      return CallInfo(
        event: event,
        phone: map['phone'] as String? ?? '',
        direction: map['direction'] as String? ?? 'outgoing',
      );
    });
    return _stream!;
  }

  Future<void> makeCall(String phone) =>
      _method.invokeMethod('makeCall', {'phone': phone});

  Future<void> endCall() => _method.invokeMethod('endCall');
  Future<void> answerCall() => _method.invokeMethod('answerCall');
  Future<void> rejectCall() => _method.invokeMethod('rejectCall');

  Future<void> holdCall({bool hold = true}) =>
      _method.invokeMethod('holdCall', {'hold': hold});

  Future<void> muteCall({required bool muted}) =>
      _method.invokeMethod('muteCall', {'muted': muted});

  Future<void> setSpeakerphone({required bool on}) =>
      _method.invokeMethod('setSpeakerphone', {'on': on});

  Future<void> sendDtmf(String digit) =>
      _method.invokeMethod('sendDtmf', {'digit': digit});

  Future<bool> isInCall() async =>
      await _method.invokeMethod<bool>('isInCall') ?? false;
}
```

---

### 3-9. به‌روزرسانی `DialerBloc`

**فایل:** `lib/features/dialer/bloc/dialer_bloc.dart`

```dart
import 'package:flutter_bloc/flutter_bloc.dart';
import '../services/native_call_service.dart';
import 'dialer_event.dart';
import 'dialer_state.dart';

class DialerBloc extends Bloc<DialerEvent, DialerState> {
  final NativeCallService _callService;
  StreamSubscription<CallInfo>? _callSub;

  DialerBloc({NativeCallService? callService})
      : _callService = callService ?? NativeCallService.instance,
        super(const DialerState()) {
    on<DigitPressed>(_onDigit);
    on<BackspacePressed>(_onBackspace);
    on<ClearDialer>(_onClear);
    on<MakeCall>(_onMakeCall);
    on<CallEventReceived>(_onCallEvent);
    on<ToggleMute>(_onToggleMute);
    on<ToggleSpeaker>(_onToggleSpeaker);
    on<EndCall>(_onEndCall);
    on<AnswerCall>(_onAnswer);
    on<RejectCall>(_onReject);

    _listenCallEvents();
  }

  void _listenCallEvents() {
    _callSub = _callService.callEvents.listen((info) {
      add(CallEventReceived(info));
    });
  }

  void _onDigit(DigitPressed e, Emitter<DialerState> emit) =>
      emit(state.copyWith(dialedNumber: state.dialedNumber + e.digit));

  void _onBackspace(BackspacePressed e, Emitter<DialerState> emit) {
    if (state.dialedNumber.isEmpty) return;
    emit(state.copyWith(
      dialedNumber: state.dialedNumber
          .substring(0, state.dialedNumber.length - 1),
    ));
  }

  void _onClear(ClearDialer e, Emitter<DialerState> emit) =>
      emit(state.copyWith(dialedNumber: ''));

  Future<void> _onMakeCall(MakeCall e, Emitter<DialerState> emit) async {
    if (state.dialedNumber.isEmpty) return;
    emit(state.copyWith(callStatus: CallStatus.connecting));
    try {
      await _callService.makeCall(state.dialedNumber);
    } catch (ex) {
      emit(state.copyWith(callStatus: CallStatus.idle, error: ex.toString()));
    }
  }

  void _onCallEvent(CallEventReceived e, Emitter<DialerState> emit) {
    final info = e.callInfo;
    switch (info.event) {
      case CallEvent.incoming:
        emit(state.copyWith(
          callStatus: CallStatus.incoming,
          activePhone: info.phone,
        ));
      case CallEvent.ringing:
        emit(state.copyWith(callStatus: CallStatus.ringing));
      case CallEvent.active:
        emit(state.copyWith(callStatus: CallStatus.active));
      case CallEvent.onHold:
        emit(state.copyWith(callStatus: CallStatus.onHold));
      case CallEvent.disconnected:
        emit(const DialerState()); // reset کامل
      case CallEvent.callFailed:
        emit(state.copyWith(
          callStatus: CallStatus.idle,
          error: 'تماس برقرار نشد',
        ));
    }
  }

  Future<void> _onToggleMute(ToggleMute e, Emitter<DialerState> emit) async {
    final muted = !state.isMuted;
    await _callService.muteCall(muted: muted);
    emit(state.copyWith(isMuted: muted));
  }

  Future<void> _onToggleSpeaker(ToggleSpeaker e, Emitter<DialerState> emit) async {
    final on = !state.isSpeakerOn;
    await _callService.setSpeakerphone(on: on);
    emit(state.copyWith(isSpeakerOn: on));
  }

  Future<void> _onEndCall(EndCall e, Emitter<DialerState> emit) async {
    await _callService.endCall();
  }

  Future<void> _onAnswer(AnswerCall e, Emitter<DialerState> emit) async {
    await _callService.answerCall();
  }

  Future<void> _onReject(RejectCall e, Emitter<DialerState> emit) async {
    await _callService.rejectCall();
  }

  @override
  Future<void> close() {
    _callSub?.cancel();
    return super.close();
  }
}
```

---

### 3-10. به‌روزرسانی `DialerState` و `DialerEvent`

**فایل:** `lib/features/dialer/bloc/dialer_state.dart`

```dart
import 'package:equatable/equatable.dart';

enum CallStatus { idle, connecting, ringing, active, incoming, onHold }

class DialerState extends Equatable {
  final String dialedNumber;
  final CallStatus callStatus;
  final String activePhone;
  final bool isMuted;
  final bool isSpeakerOn;
  final String? error;

  const DialerState({
    this.dialedNumber = '',
    this.callStatus = CallStatus.idle,
    this.activePhone = '',
    this.isMuted = false,
    this.isSpeakerOn = false,
    this.error,
  });

  DialerState copyWith({
    String? dialedNumber,
    CallStatus? callStatus,
    String? activePhone,
    bool? isMuted,
    bool? isSpeakerOn,
    String? error,
  }) => DialerState(
    dialedNumber: dialedNumber ?? this.dialedNumber,
    callStatus: callStatus ?? this.callStatus,
    activePhone: activePhone ?? this.activePhone,
    isMuted: isMuted ?? this.isMuted,
    isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
    error: error,
  );

  @override
  List<Object?> get props =>
      [dialedNumber, callStatus, activePhone, isMuted, isSpeakerOn, error];
}
```

**فایل:** `lib/features/dialer/bloc/dialer_event.dart`

```dart
import '../services/native_call_service.dart';

abstract class DialerEvent {}
class DigitPressed extends DialerEvent { final String digit; DigitPressed(this.digit); }
class BackspacePressed extends DialerEvent {}
class ClearDialer extends DialerEvent {}
class MakeCall extends DialerEvent {}
class EndCall extends DialerEvent {}
class AnswerCall extends DialerEvent {}
class RejectCall extends DialerEvent {}
class ToggleMute extends DialerEvent {}
class ToggleSpeaker extends DialerEvent {}
class HoldCall extends DialerEvent { final bool hold; HoldCall({this.hold = true}); }
class SendDtmf extends DialerEvent { final String digit; SendDtmf(this.digit); }
class CallEventReceived extends DialerEvent {
  final CallInfo callInfo;
  CallEventReceived(this.callInfo);
}
```

---

## مرحله 4 — صفحه‌های تماس Flutter

### 4-1. ساخت `IncomingCallScreen`

**فایل:** `lib/features/dialer/screens/incoming_call_screen.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../../../core/theme/app_colors.dart';

class IncomingCallScreen extends StatelessWidget {
  final String phone;
  final String? contactName;
  const IncomingCallScreen({super.key, required this.phone, this.contactName});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              // آواتار
              Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  color: AppColors.googleBlue.withOpacity(0.2),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.googleBlue, width: 2),
                ),
                child: const Icon(Icons.person, size: 56, color: Colors.white70),
              ),
              const SizedBox(height: 24),
              // نام / شماره
              Text(
                contactName ?? phone,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w300,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              if (contactName != null)
                Text(
                  phone,
                  style: const TextStyle(color: Colors.white54, fontSize: 16),
                ),
              const SizedBox(height: 16),
              const Text(
                'تماس ورودی',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
              const Spacer(flex: 3),
              // دکمه‌های پاسخ / رد
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // رد کردن
                    _CallActionButton(
                      icon: Icons.call_end,
                      color: AppColors.callRejectRed,
                      label: 'رد کردن',
                      onTap: () => context.read<DialerBloc>().add(RejectCall()),
                    ),
                    // پاسخ دادن
                    _CallActionButton(
                      icon: Icons.call,
                      color: AppColors.callAnswerGreen,
                      label: 'پاسخ',
                      onTap: () => context.read<DialerBloc>().add(AnswerCall()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72, height: 72,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 12),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }
}
```

---

### 4-2. ساخت `InCallScreen`

**فایل:** `lib/features/dialer/screens/in_call_screen.dart`

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../bloc/dialer_state.dart';
import '../../../core/theme/app_colors.dart';

class InCallScreen extends StatefulWidget {
  final String phone;
  final String? contactName;
  const InCallScreen({super.key, required this.phone, this.contactName});

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  late final Timer _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String get _formattedTime {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<DialerBloc, DialerState>(
        builder: (context, state) {
          return Scaffold(
            backgroundColor: const Color(0xFF1E1E2E),
            body: SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  // آواتار
                  Container(
                    width: 90, height: 90,
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.person, size: 50, color: Colors.white60),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    widget.contactName ?? widget.phone,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.callStatus == CallStatus.onHold
                        ? 'در انتظار'
                        : _formattedTime,
                    style: const TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                  const Spacer(flex: 2),
                  // دکمه‌های کنترل
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ControlButton(
                              icon: state.isMuted ? Icons.mic_off : Icons.mic,
                              label: state.isMuted ? 'صدا روشن' : 'بی‌صدا',
                              active: state.isMuted,
                              onTap: () => context.read<DialerBloc>().add(ToggleMute()),
                            ),
                            _ControlButton(
                              icon: state.isSpeakerOn
                                  ? Icons.volume_up
                                  : Icons.volume_down,
                              label: 'بلندگو',
                              active: state.isSpeakerOn,
                              onTap: () => context.read<DialerBloc>().add(ToggleSpeaker()),
                            ),
                            _ControlButton(
                              icon: Icons.pause,
                              label: 'نگه دار',
                              active: state.callStatus == CallStatus.onHold,
                              onTap: () => context.read<DialerBloc>().add(
                                HoldCall(hold: state.callStatus != CallStatus.onHold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 40),
                        // پایان تماس
                        GestureDetector(
                          onTap: () => context.read<DialerBloc>().add(EndCall()),
                          child: Container(
                            width: 72, height: 72,
                            decoration: BoxDecoration(
                              color: AppColors.callRejectRed,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.call_end, color: Colors.white, size: 32),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(
              color: active ? Colors.white24 : Colors.white12,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: active ? Colors.white : Colors.white54),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }
}
```

---

### 4-3. نمایش اتوماتیک صفحه‌های تماس

در `MainNavigation` یا `AppLockWrapper` یک `BlocListener` اضافه کنید:

```dart
// در بالاترین widget بعد از PermissionGate:
BlocListener<DialerBloc, DialerState>(
  listenWhen: (prev, curr) => prev.callStatus != curr.callStatus,
  listener: (context, state) {
    if (state.callStatus == CallStatus.incoming) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => IncomingCallScreen(phone: state.activePhone),
      ));
    } else if (state.callStatus == CallStatus.active) {
      // اگر IncomingCallScreen باز است، جایگزین کنید
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => InCallScreen(phone: state.activePhone),
      ));
    } else if (state.callStatus == CallStatus.idle) {
      // بستن صفحه تماس اگر باز باشد
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    }
  },
  child: child, // widget فرزند شما
)
```

---

## مرحله 5 — UI شبیه Google Phone

### 5-1. بازطراحی `DialerScreen`

**فایل:** `lib/features/dialer/screens/dialer_screen.dart`  
کل محتوای فعلی را با این جایگزین کنید:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../bloc/dialer_state.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/persian_utils.dart';

class DialerScreen extends StatelessWidget {
  const DialerScreen({super.key});

  static const _keys = [
    ('۱', ''),    ('۲', 'ABC'), ('۳', 'DEF'),
    ('۴', 'GHI'), ('۵', 'JKL'), ('۶', 'MNO'),
    ('۷', 'PQRS'),('۸', 'TUV'), ('۹', 'WXYZ'),
    ('*', ''),    ('۰', '+'),   ('#', ''),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        // بدون AppBar — مانند Google Phone
        body: SafeArea(
          child: BlocBuilder<DialerBloc, DialerState>(
            builder: (context, state) {
              return Column(
                children: [
                  const SizedBox(height: 24),
                  // نمایش شماره تایپ‌شده
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            state.dialedNumber.isEmpty
                                ? ''
                                : state.dialedNumber,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: state.dialedNumber.length > 10 ? 28 : 36,
                              fontWeight: FontWeight.w300,
                              color: theme.colorScheme.onSurface,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        if (state.dialedNumber.isNotEmpty)
                          IconButton(
                            onPressed: () =>
                                context.read<DialerBloc>().add(BackspacePressed()),
                            onLongPress: () =>
                                context.read<DialerBloc>().add(ClearDialer()),
                            icon: Icon(
                              Icons.backspace_outlined,
                              color: theme.colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  // صفحه‌کلید
                  Expanded(
                    child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 48),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 1.3,
                      ),
                      itemCount: _keys.length,
                      itemBuilder: (_, i) {
                        final (main, sub) = _keys[i];
                        return _DialerKey(
                          mainLabel: main,
                          subLabel: sub,
                          onTap: () {
                            HapticFeedback.lightImpact();
                            context.read<DialerBloc>().add(DigitPressed(main));
                          },
                          onLongPress: main == '۰'
                              ? () => context.read<DialerBloc>().add(DigitPressed('+'))
                              : null,
                          isDark: isDark,
                        );
                      },
                    ),
                  ),
                  // دکمه تماس
                  Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: GestureDetector(
                      onTap: state.dialedNumber.isEmpty
                          ? null
                          : () => context.read<DialerBloc>().add(MakeCall()),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: state.dialedNumber.isEmpty
                              ? AppColors.callAnswerGreen.withOpacity(0.4)
                              : AppColors.callAnswerGreen,
                          shape: BoxShape.circle,
                          boxShadow: state.dialedNumber.isEmpty
                              ? []
                              : [
                                  BoxShadow(
                                    color: AppColors.callAnswerGreen.withOpacity(0.4),
                                    blurRadius: 16,
                                    offset: const Offset(0, 4),
                                  )
                                ],
                        ),
                        child: const Icon(Icons.call, color: Colors.white, size: 32),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DialerKey extends StatefulWidget {
  final String mainLabel;
  final String subLabel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isDark;

  const _DialerKey({
    required this.mainLabel,
    required this.subLabel,
    required this.onTap,
    this.onLongPress,
    required this.isDark,
  });

  @override
  State<_DialerKey> createState() => _DialerKeyState();
}

class _DialerKeyState extends State<_DialerKey>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    );
    _scale = Tween(begin: 1.0, end: 0.88).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) => _ctrl.reverse(),
      onTapCancel: () => _ctrl.reverse(),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ScaleTransition(
        scale: _scale,
        child: Center(
          child: Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: widget.isDark
                  ? AppColors.dialerKeyDark
                  : AppColors.dialerKeyLight,
              shape: BoxShape.circle,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.mainLabel,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w400,
                    color: widget.isDark
                        ? AppColors.dialerKeyTextDark
                        : AppColors.dialerKeyTextLight,
                    height: 1,
                  ),
                ),
                if (widget.subLabel.isNotEmpty)
                  Text(
                    widget.subLabel,
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 1.5,
                      color: widget.isDark
                          ? AppColors.onSurfaceDarkDim
                          : AppColors.onSurfaceLightDim,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

---

### 5-2. بازطراحی `MainNavigation`

**فایل:** `lib/navigation/main_navigation.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../features/dialer/screens/dialer_screen.dart';
import '../features/call_history/screens/call_history_screen.dart';
import '../features/contacts/screens/contacts_screen.dart';
import '../features/messages/screens/threads_screen.dart';
import '../features/messages/bloc/message_bloc.dart';
import '../features/messages/bloc/message_event.dart';
import '../features/messages/bloc/message_state.dart';
import '../features/dialer/bloc/dialer_bloc.dart';
import '../features/dialer/bloc/dialer_state.dart';

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  static const _screens = [
    DialerScreen(),
    CallHistoryScreen(),
    ContactsScreen(),
    ThreadsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // listener تماس ورودی
    return BlocListener<DialerBloc, DialerState>(
      listenWhen: (p, c) => p.callStatus != c.callStatus,
      listener: (context, state) {
        if (state.callStatus == CallStatus.incoming) {
          Navigator.of(context).push(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => BlocProvider.value(
                value: context.read<DialerBloc>(),
                child: IncomingCallScreen(phone: state.activePhone),
              ),
            ),
          );
        } else if (state.callStatus == CallStatus.active) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => BlocProvider.value(
                value: context.read<DialerBloc>(),
                child: InCallScreen(phone: state.activePhone),
              ),
            ),
          );
        } else if (state.callStatus == CallStatus.idle) {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: _screens,
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          backgroundColor: theme.colorScheme.surface,
          elevation: 0,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.dialpad_outlined),
              selectedIcon: Icon(Icons.dialpad),
              label: 'شماره‌گیر',
            ),
            const NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history),
              label: 'اخیر',
            ),
            const NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'مخاطبین',
            ),
            // ✦ badge پیام‌های خوانده نشده
            BlocBuilder<MessageBloc, MessageState>(
              builder: (context, state) {
                int unread = 0;
                if (state is ThreadsLoaded) {
                  unread = state.threads.fold(0, (s, t) => s + t.unreadCount);
                }
                return NavigationDestination(
                  icon: Badge.count(
                    count: unread,
                    isLabelVisible: unread > 0,
                    child: const Icon(Icons.message_outlined),
                  ),
                  selectedIcon: Badge.count(
                    count: unread,
                    isLabelVisible: unread > 0,
                    child: const Icon(Icons.message),
                  ),
                  label: 'پیام‌ها',
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
```

---

### 5-3. بازطراحی `CallHistoryScreen` — کارت‌های شبیه Google Phone

در `lib/features/call_history/screens/widgets/call_log_tile.dart`:

```dart
import 'package:flutter/material.dart';
import '../../models/call_log_model.dart';
import '../../../../core/theme/app_colors.dart';

class CallLogTile extends StatelessWidget {
  final CallLogModel log;
  final VoidCallback? onTap;
  final VoidCallback? onCallTap;

  const CallLogTile({
    super.key,
    required this.log,
    this.onTap,
    this.onCallTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: _avatar(theme),
      title: Text(
        log.contactName ?? log.phone,
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: log.type == 'missed'
              ? AppColors.missedCallRed
              : theme.colorScheme.onSurface,
        ),
      ),
      subtitle: Row(
        children: [
          Icon(_typeIcon, size: 14, color: _typeColor),
          const SizedBox(width: 4),
          Text(_typeLabel, style: TextStyle(fontSize: 12, color: _typeColor)),
          const SizedBox(width: 8),
          Text(
            _formatTime(log.timestamp),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (log.duration > 0) ...[
            const SizedBox(width: 8),
            Text(
              _formatDuration(log.duration),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.call_outlined),
        color: AppColors.googleBlue,
        onPressed: onCallTap,
      ),
    );
  }

  Widget _avatar(ThemeData theme) {
    return CircleAvatar(
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        (log.contactName ?? log.phone).isNotEmpty
            ? (log.contactName ?? log.phone)[0].toUpperCase()
            : '?',
        style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
      ),
    );
  }

  IconData get _typeIcon => switch (log.type) {
    'missed'   => Icons.call_missed,
    'incoming' => Icons.call_received,
    _          => Icons.call_made,
  };

  Color get _typeColor => switch (log.type) {
    'missed'   => AppColors.missedCallRed,
    'incoming' => AppColors.incomingCall,
    _          => AppColors.outgoingCall,
  };

  String get _typeLabel => switch (log.type) {
    'missed'   => 'بی‌پاسخ',
    'incoming' => 'ورودی',
    _          => 'خروجی',
  };

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    if (dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}';
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}ث';
    return '${seconds ~/ 60}دق ${seconds % 60}ث';
  }
}
```

---

## مرحله 6 — Settings Feature

### 6-1. ساخت `SettingsScreen`

**فایل:** `lib/features/settings/screens/settings_screen.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../core/theme/theme_bloc.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('تنظیمات')),
        body: ListView(
          children: [
            // ── تم ────────────────────────────────────────
            _SectionHeader('ظاهر'),
            BlocBuilder<ThemeBloc, ThemeState>(
              builder: (context, state) {
                return SwitchListTile(
                  title: const Text('حالت تاریک'),
                  subtitle: const Text('تغییر بین تم روشن و تاریک'),
                  secondary: Icon(
                    state.isDark ? Icons.dark_mode : Icons.light_mode,
                  ),
                  value: state.isDark,
                  onChanged: (_) =>
                      context.read<ThemeBloc>().add(ToggleTheme()),
                );
              },
            ),
            const Divider(),
            // ── احراز هویت ────────────────────────────────
            _SectionHeader('امنیت'),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('تغییر رمز ورود'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                // navigate to auth setup
              },
            ),
            ListTile(
              leading: const Icon(Icons.pattern),
              title: const Text('تغییر الگو'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                // navigate to pattern setup
              },
            ),
            const Divider(),
            // ── درباره ────────────────────────────────────
            _SectionHeader('درباره اپ'),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('نسخه'),
              trailing: Text('1.0.0 MVP', style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
```

---

### 6-2. دکمه Settings در MainNavigation

در AppBar یا overflow menu هر صفحه، یک دکمه تنظیمات اضافه کنید:

```dart
// در هر AppBar موجود:
actions: [
  IconButton(
    icon: const Icon(Icons.settings_outlined),
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    ),
  ),
],
```

---

## مرحله 7 — رفع باگ نرمال‌سازی شماره

### 7-1. بهبود `PhoneNumberUtils`

**فایل:** `lib/core/utils/phone_number_utils.dart`  
محتوای موجود را بهبود دهید:

```dart
abstract class PhoneNumberUtils {
  /// شماره را به فرمت digits-only تبدیل می‌کند
  /// پشتیبانی از: 09xx, +989xx, 00989xx, 9xx (ایران)
  static String normalize(String phone) {
    // حذف فاصله، خط تیره، پرانتز
    var clean = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');

    // تبدیل ارقام فارسی/عربی به انگلیسی
    clean = _toEnglishDigits(clean);

    // +98 → 0
    if (clean.startsWith('+98')) {
      clean = '0${clean.substring(3)}';
    }
    // 0098 → 0
    if (clean.startsWith('0098')) {
      clean = '0${clean.substring(4)}';
    }
    // 9xx (بدون صفر) → 09xx
    if (clean.startsWith('9') && clean.length == 10) {
      clean = '0$clean';
    }

    return clean;
  }

  /// بررسی اینکه دو شماره یکی هستند
  static bool isSamePhone(String a, String b) =>
      normalize(a) == normalize(b);

  static String _toEnglishDigits(String s) {
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    const ar = '٠١٢٣٤٥٦٧٨٩';
    final buf = StringBuffer();
    for (final ch in s.runes) {
      final c = String.fromCharCode(ch);
      final fi = fa.indexOf(c);
      final ai = ar.indexOf(c);
      if (fi >= 0) buf.write(fi.toString());
      else if (ai >= 0) buf.write(ai.toString());
      else buf.write(c);
    }
    return buf.toString();
  }
}
```

---

### 7-2. به‌روزرسانی استفاده از normalize

در `MessageRepository` و `SmsService`، همه جاهایی که `thread_id` ساخته می‌شود:

```dart
// قبل:
final threadId = phone.replaceAll(RegExp(r'\D'), '');

// بعد:
import '../../core/utils/phone_number_utils.dart';
final threadId = PhoneNumberUtils.normalize(phone);
```

---

## مرحله 8 — تست نهایی و Polish

### 8-1. چک‌لیست تست دستی

```
☐ AUTH
  ☐ تنظیم PIN → ورود صحیح → ورود اشتباه
  ☐ تنظیم الگو → ورود صحیح → ورود اشتباه
  ☐ قفل خودکار هنگام رفتن به background
  ☐ تغییر از PIN به الگو در Settings

☐ MESSAGES
  ☐ ارسال پیام به یک شماره جدید
  ☐ دریافت پیام (نیاز به دستگاه واقعی)
  ☐ نمایش تعداد پیام‌های خوانده‌نشده روی badge
  ☐ MarkAsRead با باز کردن چت
  ☐ Import پیام‌های موجود دستگاه (فقط یک‌بار)

☐ CONTACTS
  ☐ افزودن مخاطب جدید
  ☐ ویرایش مخاطب
  ☐ حذف مخاطب
  ☐ جستجوی مخاطب

☐ DIALER + CALL
  ☐ تایپ شماره با keyboard
  ☐ Backspace و Long-press برای پاک کردن
  ☐ برقراری تماس (نیاز به دستگاه واقعی)
  ☐ دریافت تماس — نمایش IncomingCallScreen
  ☐ پاسخ دادن → نمایش InCallScreen + تایمر
  ☐ رد کردن تماس
  ☐ پایان دادن تماس
  ☐ Mute و Speaker

☐ CALL HISTORY
  ☐ نمایش لیست تماس‌ها
  ☐ آیکون نوع تماس (ورودی/خروجی/بی‌پاسخ)
  ☐ تماس مجدد از لیست

☐ NOTES
  ☐ افزودن یادداشت
  ☐ ویرایش یادداشت
  ☐ حذف یادداشت

☐ SETTINGS
  ☐ تغییر تم — فوری اعمال شود
  ☐ Dark mode در تمام صفحه‌ها

☐ UI
  ☐ همه صفحه‌ها RTL هستند
  ☐ Badge پیام‌های خوانده‌نشده
  ☐ هیچ overflow یا pixel overflow نداشته باشیم
  ☐ Dark mode در تمام صفحه‌ها درست است
```

---

### 8-2. دستورات بررسی نهایی

```bash
# بررسی لینتر — باید صفر warning داشته باشیم
flutter analyze

# اجرای تست‌ها
flutter test

# ساخت APK نهایی برای تست روی دستگاه
flutter build apk --release

# لاگ‌های Native در هنگام تست
adb logcat -s "CallHandler" "CallConnectionService" "SmsHandler" "flutter"
```

---

## خلاصه ترتیب اجرا

```
╔══════════════════════════════════════════════════════════════╗
║  0  pubspec.yaml + mkdir ها              (~30 دقیقه)         ║
╠══════════════════════════════════════════════════════════════╣
║  1  رفع باگ _imported + Android 13       (~1 ساعت)           ║
╠══════════════════════════════════════════════════════════════╣
║  2  AppColors + AppTheme + ThemeBloc     (~2 ساعت)           ║
║     به‌روزرسانی main.dart                                     ║
╠══════════════════════════════════════════════════════════════╣
║  3  Kotlin: CallEvent → CallHandler      (~4 ساعت)           ║
║     AndroidManifest + NativeCallService                      ║
║     DialerBloc + DialerState + DialerEvent (بازنویسی)        ║
╠══════════════════════════════════════════════════════════════╣
║  4  IncomingCallScreen + InCallScreen    (~3 ساعت)           ║
║     BlocListener در MainNavigation                           ║
╠══════════════════════════════════════════════════════════════╣
║  5  بازطراحی DialerScreen                (~3 ساعت)           ║
║     بازطراحی MainNavigation (NavigationBar + Badge)          ║
║     CallLogTile بهبود                                        ║
╠══════════════════════════════════════════════════════════════╣
║  6  SettingsScreen + ThemeBloc در main   (~2 ساعت)           ║
╠══════════════════════════════════════════════════════════════╣
║  7  بهبود PhoneNumberUtils               (~1 ساعت)           ║
╠══════════════════════════════════════════════════════════════╣
║  8  تست روی دستگاه واقعی                (~2 ساعت)            ║
╚══════════════════════════════════════════════════════════════╝
                        جمع: ~18 ساعت
```

---

## نکات مهم هنگام کار با Claude Code

وقتی از Claude Code استفاده می‌کنید، این دستورات را بدهید:

```
# برای هر مرحله به صورت جداگانه:
"طبق MVP_IMPLEMENTATION_PLAN.md مرحله 2 را پیاده‌سازی کن.
فایل‌های موجود را عوض کن، فایل جدید بساز، و تغییرات را توضیح بده."
```

**قوانین Claude Code برای این پروژه:**
- هیچ `BlocProvider` داخل Screen نساز — از `context.read<XBloc>()` استفاده کن
- تمام screen‌ها باید `Directionality(textDirection: TextDirection.rtl)` داشته باشند
- thread_id = `PhoneNumberUtils.normalize(phone)` — هرگز مستقیم `.replaceAll(RegExp(r'\D'), '')`
- batch insert همیشه با `ConflictAlgorithm.ignore`
- هیچ migration بدون bump کردن `AppConstants.databaseVersion` نکن
