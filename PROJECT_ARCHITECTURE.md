# معماری و ساختار پروژه — قاسم (Ghasem)
### Flutter Android Super App · ارتباطات پیامک / تماس / مخاطبین / یادداشت

> **نسخه سند:** 2.0 | **فاز:** MVP  
> **Stack:** Flutter 3.x · Dart 3.x · Kotlin (Native) · SQLite · BLoC  
> **هدف نهایی:** سوپر‌اپ ارتباطی با رمزنگاری پیامک و تماس بومی

---

## فهرست مطالب

1. [دیدگاه کلی معماری](#1-دیدگاه-کلی-معماری)
2. [ساختار پوشه‌ها](#2-ساختار-پوشهها)
3. [لایه‌بندی معماری](#3-لایهبندی-معماری)
4. [جریان ورودی (Entry Flow)](#4-جریان-ورودی-entry-flow)
5. [مدیریت وضعیت (State Management)](#5-مدیریت-وضعیت-state-management)
6. [پایگاه داده (Database)](#6-پایگاه-داده-database)
7. [پیپ‌لاین پیامک (SMS Pipeline)](#7-پیپلاین-پیامک-sms-pipeline)
8. [پیاده‌سازی بومی تماس (Native Call — Kotlin)](#8-پیادهسازی-بومی-تماس-native-call--kotlin)
9. [احراز هویت و قفل برنامه](#9-احراز-هویت-و-قفل-برنامه)
10. [تم و رابط کاربری (UI/UX)](#10-تم-و-رابط-کاربری-uiux)
11. [مجوزها (Permissions)](#11-مجوزها-permissions)
12. [وابستگی‌ها (Dependencies)](#12-وابستگیها-dependencies)
13. [قراردادهای کدنویسی](#13-قراردادهای-کدنویسی)
14. [نقشه راه (Roadmap)](#14-نقشه-راه-roadmap)
15. [باگ‌های شناخته‌شده و بهبودهای MVP](#15-باگهای-شناختهشده-و-بهبودهای-mvp)

---

## 1. دیدگاه کلی معماری

```
┌─────────────────────────────────────────────────┐
│               Flutter UI Layer                  │
│  (Dart · BLoC · Material 3 · RTL · Persian)     │
├─────────────────────────────────────────────────┤
│            Feature Layer (BLoC + Repo)          │
│  auth | messages | contacts | dialer |          │
│  call_history | notes | settings                │
├────────────────────┬────────────────────────────┤
│   Core Layer       │   Platform Bridge           │
│  Database·Services │  MethodChannel/EventChannel │
├────────────────────┴────────────────────────────┤
│              Kotlin Native Layer                │
│  SmsHandler · CallHandler · TelecomManager      │
└─────────────────────────────────────────────────┘
```

**اصول کلیدی:**
- تمام State از طریق BLoC مدیریت می‌شود؛ هیچ BlocProvider داخل Screen نباید وجود داشته باشد.
- هر Feature در پوشه جداگانه‌ای با الگوی `bloc / models / repositories / screens / services` قرار می‌گیرد.
- لایه Native برای SMS و Phone از `MethodChannel` و `EventChannel` استفاده می‌کند.
- پایگاه داده یک SQLite singleton است؛ هرگز مستقیماً از Screen به DB دسترسی نداشته باشید.
- تمام متن‌ها فارسی RTL هستند؛ از `Directionality(textDirection: TextDirection.rtl)` یا `RtlAppBar` استفاده کنید.

---

## 2. ساختار پوشه‌ها

```
ghasem/
├── android/
│   ├── app/
│   │   └── src/main/
│   │       ├── kotlin/com/example/communication_super_app/
│   │       │   ├── MainActivity.kt                  # FlutterActivity اصلی
│   │       │   ├── sms/
│   │       │   │   ├── SmsHandler.kt                # BroadcastReceiver + MethodChannel SMS
│   │       │   │   └── SmsEventStreamHandler.kt     # EventChannel stream for incoming SMS
│   │       │   ├── call/
│   │       │   │   ├── CallHandler.kt               # MethodChannel برای تماس
│   │       │   │   ├── CallService.kt               # InCallService پیاده‌سازی بومی
│   │       │   │   ├── CallConnectionService.kt     # ConnectionService برای TelecomManager
│   │       │   │   └── CallEventStreamHandler.kt    # EventChannel جریان رویدادهای تماس
│   │       │   └── contacts/
│   │       │       └── ContactsHandler.kt           # (اختیاری) native contacts bridge
│   │       ├── AndroidManifest.xml
│   │       └── res/
│   └── build.gradle
│
├── lib/
│   ├── main.dart                                    # نقطه ورود · MaterialApp · ThemeBloc
│   │
│   ├── core/
│   │   ├── bloc_providers/
│   │   │   └── app_bloc_providers.dart              # MultiBlocProvider کلی
│   │   ├── database/
│   │   │   ├── database_helper.dart                 # Singleton SQLite · migrations
│   │   │   └── app_constants.dart                   # DB version · table names · column names
│   │   ├── theme/
│   │   │   ├── app_theme.dart                       # ThemeData Light & Dark
│   │   │   ├── theme_bloc.dart                      # ThemeBloc · ThemeEvent · ThemeState
│   │   │   └── app_colors.dart                      # رنگ‌های برند (Google Phone palette)
│   │   ├── router/
│   │   │   └── app_router.dart                      # مسیریابی مرکزی (GoRouter)
│   │   ├── widgets/
│   │   │   ├── permission_gate.dart                 # درخواست دسته‌ای مجوزها قبل از MainNavigation
│   │   │   ├── rtl_app_bar.dart                     # AppBar فارسی RTL
│   │   │   ├── empty_state_widget.dart              # حالت خالی یکسان برای همه فیچرها
│   │   │   ├── persian_date_formatter.dart          # تبدیل تاریخ شمسی
│   │   │   └── custom_bottom_nav.dart               # Bottom nav با طراحی Google Phone
│   │   ├── services/
│   │   │   ├── permission_service.dart              # Wrapper برای permission_handler
│   │   │   ├── notification_service.dart            # نوتیف‌های پیامک و تماس ورودی
│   │   │   └── app_lock_service.dart                # وضعیت قفل در حافظه
│   │   └── utils/
│   │       ├── persian_utils.dart                   # تبدیل ارقام فارسی · جستجوی RTL
│   │       └── phone_number_utils.dart              # نرمال‌سازی شماره تلفن (digits-only)
│   │
│   ├── features/
│   │   │
│   │   ├── authentication/
│   │   │   ├── bloc/
│   │   │   │   ├── auth_bloc.dart
│   │   │   │   ├── auth_event.dart
│   │   │   │   └── auth_state.dart                  # AuthNotSet | AuthSet | AuthAuthenticated
│   │   │   ├── models/
│   │   │   │   └── auth_config.dart                 # نوع auth (PIN/Pattern) + credential
│   │   │   ├── repositories/
│   │   │   │   └── auth_repository.dart             # flutter_secure_storage wrapper
│   │   │   └── screens/
│   │   │       ├── auth_wrapper_screen.dart         # Router: setup vs entry vs authenticated
│   │   │       ├── pin_setup_screen.dart
│   │   │       ├── pin_entry_screen.dart
│   │   │       ├── pattern_setup_screen.dart
│   │   │       └── pattern_entry_screen.dart
│   │   │
│   │   ├── messages/
│   │   │   ├── bloc/
│   │   │   │   ├── message_bloc.dart
│   │   │   │   ├── message_event.dart               # LoadThreads | SendMessage | ReceiveMessage | MarkRead
│   │   │   │   └── message_state.dart               # MessageLoading | ThreadsLoaded | MessagesLoaded | MessageError
│   │   │   ├── models/
│   │   │   │   ├── message_model.dart               # id · phone_number · body · timestamp · type · is_read · thread_id
│   │   │   │   └── thread_model.dart                # thread_id · contact_name · last_message · unread_count
│   │   │   ├── repositories/
│   │   │   │   └── message_repository.dart          # CRUD روی جدول messages
│   │   │   ├── services/
│   │   │   │   ├── sms_service.dart                 # sendSms · importDeviceMessages · listenToIncomingSms
│   │   │   │   └── native_sms_service.dart          # MethodChannel + EventChannel wrapper
│   │   │   └── screens/
│   │   │       ├── threads_screen.dart              # لیست مکالمات
│   │   │       ├── conversation_screen.dart         # صفحه چت
│   │   │       └── widgets/
│   │   │           ├── message_bubble.dart
│   │   │           ├── thread_tile.dart
│   │   │           └── sms_composer.dart
│   │   │
│   │   ├── contacts/
│   │   │   ├── bloc/
│   │   │   │   ├── contact_bloc.dart
│   │   │   │   ├── contact_event.dart               # LoadContacts | AddContact | UpdateContact | DeleteContact | SearchContacts
│   │   │   │   └── contact_state.dart
│   │   │   ├── models/
│   │   │   │   └── contact_model.dart               # id · name · phone · email · note · avatar_path
│   │   │   ├── repositories/
│   │   │   │   └── contact_repository.dart          # CRUD جدول contacts + device sync
│   │   │   └── screens/
│   │   │       ├── contacts_screen.dart             # لیست مخاطبین با جستجو
│   │   │       ├── contact_detail_screen.dart
│   │   │       ├── contact_form_screen.dart         # افزودن / ویرایش
│   │   │       └── widgets/
│   │   │           └── contact_avatar.dart
│   │   │
│   │   ├── dialer/
│   │   │   ├── bloc/
│   │   │   │   ├── dialer_bloc.dart
│   │   │   │   ├── dialer_event.dart                # DigitPressed | BackspacePressed | CallPressed | ClearPressed
│   │   │   │   └── dialer_state.dart
│   │   │   ├── services/
│   │   │   │   └── native_call_service.dart         # MethodChannel + EventChannel wrapper برای تماس
│   │   │   └── screens/
│   │   │       ├── dialer_screen.dart               # صفحه‌کلید شمارگیر (شبیه Google Phone)
│   │   │       ├── in_call_screen.dart              # ✦ جدید: صفحه حین تماس بومی
│   │   │       ├── incoming_call_screen.dart        # ✦ جدید: صفحه تماس ورودی
│   │   │       └── widgets/
│   │   │           ├── dial_button.dart
│   │   │           └── in_call_controls.dart        # بلندگو · بی‌صدا · پایان تماس · DTMF
│   │   │
│   │   ├── call_history/
│   │   │   ├── bloc/
│   │   │   │   ├── call_history_bloc.dart
│   │   │   │   ├── call_history_event.dart          # LoadCallLogs | DeleteCallLog | ClearHistory
│   │   │   │   └── call_history_state.dart
│   │   │   ├── models/
│   │   │   │   └── call_log_model.dart              # id · phone · contact_name · duration · type(in/out/missed) · timestamp
│   │   │   ├── repositories/
│   │   │   │   └── call_log_repository.dart
│   │   │   ├── services/
│   │   │   │   └── call_log_service.dart            # خواندن call log از دستگاه + ذخیره داخلی
│   │   │   └── screens/
│   │   │       ├── call_history_screen.dart
│   │   │       └── widgets/
│   │   │           └── call_log_tile.dart           # آیکون نوع تماس · نام/شماره · مدت · زمان
│   │   │
│   │   ├── notes/
│   │   │   ├── bloc/
│   │   │   │   ├── notes_bloc.dart
│   │   │   │   ├── notes_event.dart                 # LoadNotes | AddNote | UpdateNote | DeleteNote
│   │   │   │   └── notes_state.dart
│   │   │   ├── models/
│   │   │   │   └── note_model.dart                  # id · title · body · created_at · updated_at
│   │   │   ├── repositories/
│   │   │   │   └── notes_repository.dart
│   │   │   └── screens/
│   │   │       ├── notes_screen.dart
│   │   │       ├── note_detail_screen.dart
│   │   │       └── note_editor_screen.dart
│   │   │
│   │   └── settings/                                # ✦ فیچر جدید برای MVP
│   │       ├── bloc/
│   │       │   ├── settings_bloc.dart
│   │       │   ├── settings_event.dart              # ToggleTheme | ChangeAuthType | ResetAuth
│   │       │   └── settings_state.dart
│   │       └── screens/
│   │           └── settings_screen.dart             # تم · احراز هویت · درباره اپ
│   │
│   └── navigation/
│       └── main_navigation.dart                     # BottomNavigationBar · 4 تب + تنظیمات
│
├── test/
│   ├── unit/
│   │   ├── message_repository_test.dart
│   │   ├── contact_repository_test.dart
│   │   └── phone_number_utils_test.dart
│   ├── bloc/
│   │   ├── message_bloc_test.dart
│   │   └── auth_bloc_test.dart
│   └── widget/
│       └── widget_test.dart
│
├── pubspec.yaml
├── analysis_options.yaml
└── CLAUDE.md
```

---

## 3. لایه‌بندی معماری

### الگوی Feature-First با Clean Architecture

```
┌─────────────────────────────────────┐
│            Screens (UI)             │  فقط BlocBuilder / BlocListener
│         context.read<XBloc>()       │  بدون منطق کسب‌وکار
├─────────────────────────────────────┤
│              BLoC                   │  رویداد → وضعیت
│     Events → States (Bloc)          │  فراخوانی Repository
├─────────────────────────────────────┤
│           Repository                │  انتزاع دسترسی به داده
│    (SQLite / SharedPrefs / Native)  │  هیچ اطلاعی از UI ندارد
├─────────────────────────────────────┤
│     DatabaseHelper / Services       │  Singleton‌ها
│  (SmsService, NativeCallService)    │  ارتباط با لایه بومی
└─────────────────────────────────────┘
```

**قوانین اجباری:**
- Screen فقط با BLoC صحبت می‌کند؛ هرگز مستقیم به Repository دسترسی ندارد.
- BLoC از Repository می‌خواند، نه از DatabaseHelper مستقیم.
- DatabaseHelper تنها نقطه دسترسی به SQLite است.
- Services جداکننده لایه Flutter از لایه بومی Android هستند.

---

## 4. جریان ورودی (Entry Flow)

```
main.dart
  └─► MaterialApp (ThemeBloc)
        └─► AppBlocProviders (MultiBlocProvider)
              └─► AppLockWrapper (AppLifecycleState listener)
                    └─► AuthWrapperScreen
                          ├─[AuthNotSet]──► PinSetupScreen / PatternSetupScreen
                          ├─[AuthSet]─────► PinEntryScreen / PatternEntryScreen
                          └─[Authenticated]► PermissionGate
                                              └─► MainNavigation
                                                    ├── Tab 0: DialerScreen
                                                    ├── Tab 1: CallHistoryScreen
                                                    ├── Tab 2: ContactsScreen
                                                    ├── Tab 3: ThreadsScreen
                                                    └── Tab 4: NotesScreen
```

**نکته مهم `PermissionGate`:**  
تمام مجوزهای runtime (SMS · Phone · Contacts · Microphone) به‌صورت دسته‌ای قبل از ساخته‌شدن `MainNavigation` درخواست می‌شوند. این از crash ناشی از چندین `IndexedStack` که همزمان Permission می‌خواهند جلوگیری می‌کند.

---

## 5. مدیریت وضعیت (State Management)

### BLoC‌های موجود در AppBlocProviders

| BLoC | وابستگی | رویدادهای اصلی |
|------|---------|----------------|
| `AuthBloc` | `AuthRepository` | `CheckAuthStatus`, `SetPin`, `VerifyPin`, `SetPattern`, `VerifyPattern`, `Logout` |
| `MessageBloc` | `MessageRepository`, `SmsService` | `LoadThreads`, `LoadMessages`, `SendMessage`, `ReceiveMessage`, `MarkAsRead` |
| `ContactBloc` | `ContactRepository` | `LoadContacts`, `AddContact`, `UpdateContact`, `DeleteContact`, `SearchContacts` |
| `DialerBloc` | `NativeCallService` | `DigitPressed`, `BackspacePressed`, `CallPressed`, `EndCall` |
| `CallHistoryBloc` | `CallLogRepository`, `CallLogService` | `LoadCallLogs`, `DeleteLog`, `ClearAll` |
| `NotesBloc` | `NotesRepository` | `LoadNotes`, `AddNote`, `UpdateNote`, `DeleteNote` |
| `ThemeBloc` | `SharedPreferences` | `ToggleTheme`, `LoadTheme` |
| `SettingsBloc` | `AuthRepository`, `AppLockService` | `ChangeAuthType`, `UpdateLockTimeout` |

### نگهبان‌های مهم در MessageBloc

```dart
// جلوگیری از سفید شدن صفحه چت هنگام دریافت SMS در پس‌زمینه
if (state is ThreadsLoaded || state is MessagesLoaded) {
  // LoadThreads را بدون emit(MessageLoading()) پردازش کن
}

// کش نام مخاطبین — فقط یک‌بار در طول session ساخته می‌شود
Map<String, String> _cachedPhoneToName = {};
```

---

## 6. پایگاه داده (Database)

**فایل:** `lib/core/database/database_helper.dart`  
**نام:** `communication_app.db` · **نسخه:** 3

### طرح جداول (Schema)

```sql
-- مخاطبین
CREATE TABLE contacts (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL,
  phone       TEXT NOT NULL,
  email       TEXT,
  note        TEXT,
  avatar_path TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

-- پیام‌ها
CREATE TABLE messages (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  phone_number TEXT NOT NULL,
  thread_id    TEXT NOT NULL,   -- شماره نرمال‌شده (فقط ارقام)
  body         TEXT NOT NULL,
  timestamp    INTEGER NOT NULL,
  type         TEXT NOT NULL,   -- 'sent' | 'received'
  is_read      INTEGER NOT NULL DEFAULT 0,  -- 0=unread, 1=read
  UNIQUE(phone_number, body, timestamp, type) -- DB v3: جلوگیری از تکرار
);
CREATE INDEX idx_messages_thread ON messages(thread_id, timestamp DESC);

-- تماس‌ها
CREATE TABLE call_logs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  phone        TEXT NOT NULL,
  contact_name TEXT,
  duration     INTEGER DEFAULT 0,   -- ثانیه
  type         TEXT NOT NULL,       -- 'incoming' | 'outgoing' | 'missed'
  timestamp    INTEGER NOT NULL
);

-- یادداشت‌ها
CREATE TABLE notes (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  title      TEXT,
  body       TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
```

### ثوابت اصلی (AppConstants)

```dart
class AppConstants {
  static const String dbName = 'communication_app.db';
  static const int databaseVersion = 3;

  // جداول
  static const String tableContacts   = 'contacts';
  static const String tableMessages   = 'messages';
  static const String tableCallLogs   = 'call_logs';
  static const String tableNotes      = 'notes';

  // thread_id = شماره نرمال‌شده (فقط ارقام)
  // messages.is_read: 0=unread, 1=read
  // sent messages همیشه is_read=1 ذخیره می‌شوند

  // مهاجرت‌ها فقط در DatabaseHelper._onUpgrade
}
```

**قانون batch insert:**
```dart
// همیشه از ConflictAlgorithm.ignore استفاده کنید
await db.insert(
  AppConstants.tableMessages,
  message.toMap(),
  conflictAlgorithm: ConflictAlgorithm.ignore,
);
```

---

## 7. پیپ‌لاین پیامک (SMS Pipeline)

### دریافت SMS

```
SmsHandler.kt (BroadcastReceiver: SMS_RECEIVED)
  └─► EventChannel: com.example.communication_super_app/sms_events
        └─► NativeSmsService.onSmsReceived (Stream)
              └─► SmsService.listenToIncomingSms()
                    ├─► MessageRepository.insertMessage()
                    ├─► NotificationService.showSmsNotification()
                    └─► MessageBloc.add(ReceiveMessage(...))
```

**نگهبان‌های مهم:**
- `NativeSmsService.initialize()` فقط یک‌بار فراخوانی می‌شود (`_initialized` guard).
- `SmsService._listening` از ثبت چندباره listener جلوگیری می‌کند.
- `MessageBloc` روی اولین `LoadThreads` گوش دادن را شروع می‌کند.

### ارسال SMS

```
SmsService.sendSms(phone, body)
  └─► NativeSmsService.sendSms()
        └─► MethodChannel: com.example.communication_super_app/sms
              └─► SmsHandler.kt.sendSms()
                    └─► SmsManager.sendTextMessage()

// کدهای خطا از native:
// NO_SIM_CARD | NO_SERVICE | PERMISSION_DENIED | SMS_SEND_FAILED
```

### Import پیام‌های دستگاه

```dart
// فقط یک‌بار در session اجرا می‌شود
static bool _imported = false;

Future<void> importDeviceMessages() async {
  if (_imported) return;
  _imported = true;
  // inbox: حداکثر 500 پیام
  // sent: حداکثر 500 پیام
  // Batch insert با ConflictAlgorithm.ignore
}
```

---

## 8. پیاده‌سازی بومی تماس (Native Call — Kotlin)

> ⚡ **این بخش پیاده‌سازی نشده و باید در MVP اضافه شود.**

### معماری بومی تماس

```
Flutter (Dart)
  ├─► MethodChannel: com.example.communication_super_app/call
  │     ├─ makeCall(phoneNumber)
  │     ├─ endCall()
  │     ├─ answerCall()
  │     ├─ rejectCall()
  │     ├─ holdCall()
  │     ├─ muteCall(bool)
  │     ├─ setSpeakerphone(bool)
  │     └─ sendDtmf(digit)
  └─► EventChannel: com.example.communication_super_app/call_events
        └─ Stream<CallEvent>: INCOMING | RINGING | ACTIVE | HOLDING | DISCONNECTED
```

### فایل‌های Kotlin مورد نیاز

#### `CallConnectionService.kt`
```kotlin
// ثبت در AndroidManifest.xml با permission BIND_TELECOM_CONNECTION_SERVICE
class CallConnectionService : ConnectionService() {

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val connection = CallConnection()
        connection.setDialing()
        return connection
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val connection = CallConnection()
        connection.setRinging()
        // اطلاع‌رسانی به Flutter از طریق EventChannel
        CallEventStreamHandler.sendEvent(CallEvent.INCOMING)
        return connection
    }
}
```

#### `CallConnection.kt`
```kotlin
class CallConnection : Connection() {
    override fun onAnswer() {
        setActive()
        CallEventStreamHandler.sendEvent(CallEvent.ACTIVE)
    }

    override fun onReject() {
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
        CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED)
    }

    override fun onDisconnect() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        CallEventStreamHandler.sendEvent(CallEvent.DISCONNECTED)
    }

    override fun onHold() {
        setOnHold()
        CallEventStreamHandler.sendEvent(CallEvent.HOLDING)
    }

    override fun onUnhold() {
        setActive()
        CallEventStreamHandler.sendEvent(CallEvent.ACTIVE)
    }
}
```

#### `CallHandler.kt`
```kotlin
class CallHandler(private val context: Context, private val flutterEngine: FlutterEngine) {

    private val methodChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "com.example.communication_super_app/call"
    )

    init {
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "makeCall" -> {
                    val phone = call.argument<String>("phone") ?: return@setMethodCallHandler
                    makeCall(phone, result)
                }
                "endCall"       -> { endCall(); result.success(null) }
                "answerCall"    -> { answerCall(); result.success(null) }
                "rejectCall"    -> { rejectCall(); result.success(null) }
                "muteCall"      -> {
                    val mute = call.argument<Boolean>("mute") ?: false
                    muteCall(mute); result.success(null)
                }
                "setSpeakerphone" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    setSpeakerphone(on); result.success(null)
                }
                "sendDtmf" -> {
                    val digit = call.argument<String>("digit") ?: return@setMethodCallHandler
                    sendDtmf(digit); result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun makeCall(phone: String, result: MethodChannel.Result) {
        try {
            val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val uri = Uri.fromParts("tel", phone, null)
            val extras = Bundle()
            telecomManager.placeCall(uri, extras)
            result.success(null)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        }
    }

    private fun endCall() {
        CallConnectionService.currentConnection?.onDisconnect()
    }

    private fun answerCall() {
        CallConnectionService.currentConnection?.onAnswer()
    }

    private fun rejectCall() {
        CallConnectionService.currentConnection?.onReject()
    }

    private fun muteCall(muted: Boolean) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.isMicrophoneMute = muted
    }

    private fun setSpeakerphone(on: Boolean) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.isSpeakerphoneOn = on
    }

    private fun sendDtmf(digit: String) {
        CallConnectionService.currentConnection?.playDtmfTone(digit[0])
    }
}
```

#### `CallEventStreamHandler.kt`
```kotlin
object CallEventStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun sendEvent(event: CallEvent) {
        // از Main thread ارسال می‌کنیم
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(event.name)
        }
    }
}

enum class CallEvent { INCOMING, RINGING, ACTIVE, HOLDING, DISCONNECTED }
```

#### `AndroidManifest.xml` — اضافه‌کردن مجوزها و service

```xml
<!-- مجوزها -->
<uses-permission android:name="android.permission.CALL_PHONE" />
<uses-permission android:name="android.permission.READ_CALL_LOG" />
<uses-permission android:name="android.permission.WRITE_CALL_LOG" />
<uses-permission android:name="android.permission.READ_PHONE_STATE" />
<uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.PROCESS_OUTGOING_CALLS" />

<!-- ConnectionService -->
<service
    android:name=".call.CallConnectionService"
    android:permission="android.permission.BIND_TELECOM_CONNECTION_SERVICE"
    android:exported="true">
    <intent-filter>
        <action android:name="android.telecom.ConnectionService" />
    </intent-filter>
</service>
```

### طرف Dart — `NativeCallService`

```dart
class NativeCallService {
  static const _methodChannel = MethodChannel(
    'com.example.communication_super_app/call',
  );
  static const _eventChannel = EventChannel(
    'com.example.communication_super_app/call_events',
  );

  bool _initialized = false;

  Stream<CallEvent>? _callEventStream;

  Stream<CallEvent> get callEvents {
    _callEventStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((e) => CallEvent.values.byName(e as String));
    return _callEventStream!;
  }

  Future<void> makeCall(String phone) async {
    await _methodChannel.invokeMethod('makeCall', {'phone': phone});
  }

  Future<void> endCall() => _methodChannel.invokeMethod('endCall');
  Future<void> answerCall() => _methodChannel.invokeMethod('answerCall');
  Future<void> rejectCall() => _methodChannel.invokeMethod('rejectCall');
  Future<void> muteCall(bool muted) =>
      _methodChannel.invokeMethod('muteCall', {'mute': muted});
  Future<void> setSpeakerphone(bool on) =>
      _methodChannel.invokeMethod('setSpeakerphone', {'on': on});
  Future<void> sendDtmf(String digit) =>
      _methodChannel.invokeMethod('sendDtmf', {'digit': digit});
}

enum CallEvent { incoming, ringing, active, holding, disconnected }
```

---

## 9. احراز هویت و قفل برنامه

```
flutter_secure_storage
  └─► AuthRepository
        ├─ getAuthType()      → 'pin' | 'pattern' | null
        ├─ savePin(hash)
        ├─ verifyPin(input)
        ├─ savePattern(hash)
        └─ verifyPattern(input)

AppLockService (Singleton در حافظه)
  ├─ isLocked: bool
  ├─ lock()
  └─ unlock()

AppLockWrapper (StatefulWidget)
  └─ AppLifecycleState.paused → AppLockService.lock()
  └─ AppLifecycleState.resumed → اگر قفل بود → AuthWrapperScreen
```

**بهبود پیشنهادی:**  
افزودن timeout قابل تنظیم (۳۰ ثانیه / ۱ دقیقه / ۵ دقیقه / هرگز) در SettingsBloc.

---

## 10. تم و رابط کاربری (UI/UX)

### طرح رنگ Google Phone (Material 3)

```dart
// app_colors.dart
class AppColors {
  // Light Theme
  static const primaryLight     = Color(0xFF1A73E8); // Google Blue
  static const surfaceLight     = Color(0xFFFFFFFF);
  static const backgroundLight  = Color(0xFFF8F9FA);
  static const onSurfaceLight   = Color(0xFF202124);
  static const callGreen        = Color(0xFF34A853); // پاسخ دادن
  static const callRed          = Color(0xFFEA4335); // رد کردن / قطع

  // Dark Theme
  static const primaryDark      = Color(0xFF8AB4F8);
  static const surfaceDark      = Color(0xFF202124);
  static const backgroundDark   = Color(0xFF121212);
  static const onSurfaceDark    = Color(0xFFE8EAED);

  // Semantic
  static const missedCall       = Color(0xFFEA4335);
  static const incomingCall     = Color(0xFF34A853);
  static const outgoingCall     = Color(0xFF1A73E8);
}
```

### ThemeBloc

```dart
// theme_bloc.dart
class ThemeBloc extends Bloc<ThemeEvent, ThemeState> {
  ThemeBloc() : super(ThemeState.light) {
    on<ToggleTheme>((event, emit) {
      emit(state == ThemeState.light ? ThemeState.dark : ThemeState.light);
      _savePreference(state);
    });
    on<LoadTheme>((event, emit) async {
      final isDark = await _loadPreference();
      emit(isDark ? ThemeState.dark : ThemeState.light);
    });
  }
}
```

### قوانین RTL

```dart
// هر screen جدید باید این wrapper را داشته باشد:
return Directionality(
  textDirection: TextDirection.rtl,
  child: Scaffold(
    appBar: RtlAppBar(title: 'عنوان'),
    body: ...,
  ),
);
```

### شباهت به Google Phone — عناصر کلیدی UI

| عنصر | مشخصات |
|------|---------|
| Bottom Navigation | آیکون‌های Filled + Outlined · label فارسی · badge تعداد پیام |
| Dialer | دکمه‌های گرد با ripple · باکس شماره RTL · دکمه تماس سبز بزرگ |
| Call Screen | کارت مخاطب · دکمه‌های دایره‌ای (mute/speaker/hold/end) |
| Incoming Call | دو دکمه بزرگ سبز/قرمز · انیمیشن حلقه |
| Thread List | Avatar · نام/شماره · پیش‌نمایش پیام · تاریخ · badge |
| Contact List | Alphabetical sticky header · Fast scroll |

---

## 11. مجوزها (Permissions)

### تعریف در AndroidManifest.xml

```xml
<!-- پیامک -->
<uses-permission android:name="android.permission.RECEIVE_SMS" />
<uses-permission android:name="android.permission.READ_SMS" />
<uses-permission android:name="android.permission.SEND_SMS" />
<!-- تماس -->
<uses-permission android:name="android.permission.CALL_PHONE" />
<uses-permission android:name="android.permission.READ_CALL_LOG" />
<uses-permission android:name="android.permission.WRITE_CALL_LOG" />
<uses-permission android:name="android.permission.READ_PHONE_STATE" />
<uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<!-- مخاطبین -->
<uses-permission android:name="android.permission.READ_CONTACTS" />
<uses-permission android:name="android.permission.WRITE_CONTACTS" />
<!-- نوتیفیکیشن -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<!-- هندلر پیش‌فرض SMS -->
<uses-permission android:name="android.permission.BROADCAST_SMS" />
```

### مجوزهای Runtime در PermissionGate

```dart
// ترتیب درخواست — در یک مرحله
final permissions = [
  Permission.sms,
  Permission.phone,
  Permission.contacts,
  Permission.microphone,
  Permission.notification, // Android 13+
];
```

---

## 12. وابستگی‌ها (Dependencies)

### `pubspec.yaml`

```yaml
dependencies:
  flutter:
    sdk: flutter

  # State Management
  flutter_bloc: ^8.1.6
  equatable: ^2.0.5

  # Database
  sqflite: ^2.3.3
  path: ^1.9.0

  # Storage
  flutter_secure_storage: ^9.2.2
  shared_preferences: ^2.3.2

  # SMS (plugin bridge — native بومی است)
  telephony: ^0.2.0          # برای import پیام‌های device

  # Permissions
  permission_handler: ^11.3.1

  # Notifications
  flutter_local_notifications: ^17.2.2

  # Navigation
  go_router: ^14.2.7         # ✦ بهبود: جایگزین Navigator.push خام

  # UI
  flutter_svg: ^2.0.10+1
  cached_network_image: ^3.3.1
  shimmer: ^3.0.0            # loading skeleton

  # Contacts
  fast_contacts: ^3.0.1      # خواندن سریع مخاطبین دستگاه

  # Utils
  intl: ^0.19.0
  shamsi_date: ^1.1.2        # تاریخ شمسی

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  bloc_test: ^9.1.7
  mocktail: ^1.0.4
```

---

## 13. قراردادهای کدنویسی

### نام‌گذاری

| نوع | الگو | مثال |
|-----|------|------|
| فایل | `snake_case.dart` | `message_bloc.dart` |
| کلاس | `PascalCase` | `MessageBloc` |
| متغیر/متد | `camelCase` | `sendMessage()` |
| ثابت | `camelCase` | `AppConstants.dbName` |
| Event | `PascalCase + Event` | `LoadThreadsEvent` |
| State | `PascalCase + State` | `ThreadsLoadedState` |

### قوانین BLoC

```dart
// ✅ درست — از context استفاده کنید
context.read<MessageBloc>().add(LoadThreadsEvent());

// ❌ اشتباه — BlocProvider داخل screen نسازید
BlocProvider(
  create: (_) => MessageBloc(...), // ❌
  child: ...,
)
```

### قوانین Database

```dart
// ✅ همیشه ConflictAlgorithm.ignore در batch insert
await db.insert(table, map, conflictAlgorithm: ConflictAlgorithm.ignore);

// ✅ thread_id همیشه normalized phone number
String normalizePhone(String phone) =>
    phone.replaceAll(RegExp(r'\D'), '');

// ✅ sent messages با is_read=1 ذخیره می‌شوند
```

---

## 14. نقشه راه (Roadmap)

### فاز MVP (جاری)
- [x] احراز هویت (PIN / Pattern)
- [x] مدیریت مخاطبین (CRUD)
- [x] ارسال و دریافت SMS
- [x] تاریخچه پیام‌ها
- [x] تاریخچه تماس‌ها
- [x] یادداشت‌های ساده
- [x] تم تاریک / روشن
- [ ] **پیاده‌سازی بومی تماس (Kotlin)** ← اولویت اول
- [ ] **UI شبیه Google Phone** ← اولویت دوم
- [ ] رفع باگ‌های شناخته‌شده ← اولویت سوم

### فاز سازمانی
- [ ] رمزنگاری پایه پیامک (AES-256)
- [ ] دفترچه مخاطبین رمزشده (SQLCipher)
- [ ] سیستم کد فعال‌سازی
- [ ] پشتیبان‌گیری و بازیابی
- [ ] دسته‌بندی مخاطبین (گروه‌ها)
- [ ] لیست سیاه و سفید
- [ ] ارسال پیام گروهی
- [ ] مدیریت Dual SIM

### فاز بازار (نهایی)
- [ ] رمزنگاری E2E (Double Ratchet)
- [ ] رمزنگاری پسا‌کوانتومی (CRYSTALS-Kyber)
- [ ] ارسال موقعیت مکانی از طریق SMS
- [ ] پاک‌سازی خودکار با trigger
- [ ] پشتیبانی چندزبانه (فارسی + انگلیسی)
- [ ] بررسی نسخه iOS

---

## 15. باگ‌های شناخته‌شده و بهبودهای MVP

### باگ‌های اولویت بالا

| # | توضیح | راه‌حل |
|---|-------|---------|
| B1 | صفحه چت هنگام دریافت SMS در پس‌زمینه سفید می‌شود | نگهبان `LoadThreads` در MessageBloc — **پیاده‌سازی شده، بررسی کنید** |
| B2 | `NativeSmsService.initialize()` چندبار فراخوانی می‌شود | Guard `_initialized` — **پیاده‌سازی شده، بررسی کنید** |
| B3 | تماس بومی پیاده‌سازی نشده — کرش در Dialer | پیاده‌سازی `CallConnectionService` ← **اولویت** |
| B4 | مجوزها روی Android 13+ (API 33) POST_NOTIFICATIONS لازم دارد | اضافه‌کردن به PermissionGate |
| B5 | شماره‌های بین‌الملل (+98) با نرمال‌سازی تداخل دارند | بهبود `normalizePhone()` برای handle کردن `+98`, `0098`, `0` |
| B6 | Import پیام‌های دستگاه — flag `_imported` بعد از restart از دست می‌رود | ذخیره flag در SharedPreferences به‌جای متغیر static |

### بهبودهای UI/UX

| # | توضیح | اولویت |
|---|-------|--------|
| U1 | دکمه‌های شماره‌گیر باید مطابق Google Phone باشند (حروف زیر عدد) | بالا |
| U2 | انیمیشن تماس ورودی (حلقه‌های متحرک) | متوسط |
| U3 | Skeleton loading برای لیست مکالمات و مخاطبین | متوسط |
| U4 | Empty state برای صفحه‌های خالی | متوسط |
| U5 | Long press روی پیام: کپی، حذف، اطلاعات | بالا |
| U6 | Swipe to delete در لیست مکالمات | متوسط |
| U7 | Pull to refresh در تمام لیست‌ها | پایین |
| U8 | FAB (Floating Action Button) برای پیام جدید / تماس جدید | بالا |

### بهبودهای معماری

| # | توضیح |
|---|-------|
| A1 | جایگزینی `Navigator.push` خام با `GoRouter` برای navigation یکپارچه |
| A2 | اضافه‌کردن `SettingsFeature` مستقل برای مدیریت تم و احراز هویت |
| A3 | استفاده از `Freezed` برای مدل‌ها و State‌های immutable |
| A4 | لایه `Repository` انتزاعی با Interface برای تست‌پذیری بهتر |
| A5 | جدا کردن `NotificationService` از `SmsService` |

---

## دستورات مفید

```bash
flutter pub get                    # نصب وابستگی‌ها
flutter run                        # اجرا روی دستگاه متصل
flutter run --release              # اجرا در حالت release
flutter build apk                  # ساخت APK debug
flutter build apk --release        # ساخت APK release
flutter analyze                    # اجرای linter
flutter test                       # اجرای تمام تست‌ها
flutter test test/bloc/            # فقط تست‌های BLoC

# مشاهده لاگ native (Kotlin)
adb logcat -s "CallHandler" "SmsHandler" "CallConnectionService"
```

---

*سند توسط Claude Sonnet 4.6 بر اساس کد پروژه، CLAUDE.md، و مستندات فنی SMS/Phone تولید شده است.*
