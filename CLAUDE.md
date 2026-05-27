# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get          # Install dependencies
flutter run              # Run on connected device/emulator
flutter run --release    # Run in release mode
flutter build apk        # Build Android APK (debug)
flutter build apk --release  # Build release APK
flutter analyze          # Run linter (flutter_lints)
flutter test             # Run all tests
flutter test test/widget_test.dart  # Run a single test file
```

## Architecture

This is a Flutter Android SMS/phone app with a Persian (RTL) UI. The internal app name is **قاسم** (Ghasem).

### Entry flow

`main.dart` → `AppBlocProviders` (MultiBlocProvider) → `AppLockWrapper` → `AuthWrapperScreen` → `PermissionGate` → `MainNavigation`

- **`AppBlocProviders`** (`lib/core/bloc_providers/`) provisions all BLoCs globally at startup.
- **`AuthWrapperScreen`** routes based on `AuthBloc` state: `AuthNotSet` → PIN setup, `AuthSet` → PIN entry, `AuthAuthenticated` → `PermissionGate`.
- **`PermissionGate`** (`lib/core/widgets/`) batches all runtime permission requests (SMS, Phone, Contacts) via `PermissionService` *before* `MainNavigation` is built — this prevents a crash caused by multiple `IndexedStack` screens simultaneously requesting permissions.
- **`MainNavigation`** is a bottom-nav shell with 4 tabs: Dialer (0), Call History (1), Contacts (2), Messages (3).

### Feature structure

Each feature under `lib/features/<name>/` follows the pattern:
```
bloc/       # BLoC events, states, bloc class
models/     # Data models
repositories/ # SQLite access via DatabaseHelper
screens/    # Flutter UI widgets
services/   # (messages, call_history only) Native/plugin bridging
```

Features: `authentication`, `messages`, `contacts`, `dialer`, `call_history`, `notes`.

### State management

All state is BLoC (`flutter_bloc`). BLoCs are provided globally in `AppBlocProviders` — do not create new `BlocProvider`s inside screens; use `context.read<XBloc>()` / `context.watch<XBloc>()`.

### Database

Single SQLite database (`communication_app.db`, version 3) managed by `DatabaseHelper` singleton (`lib/core/database/`). Tables: `contacts`, `messages`, `notes`, `call_logs`. Constants in `AppConstants`.

**Schema invariants:**
- `messages.thread_id` is the digits-only normalized phone number.
- `messages` has a unique index on `(phone_number, body, timestamp, type)` (DB v3) — all batch inserts must use `ConflictAlgorithm.ignore` to silently skip duplicates.
- `messages.is_read` marks unread received messages; sent messages are always inserted as `is_read = 1`.

Migrations live in `DatabaseHelper._onUpgrade`. When bumping `AppConstants.databaseVersion`, add a migration block there.

### SMS pipeline

**Receiving:**
1. `SmsHandler.kt` (Android) registers a `BroadcastReceiver` for `SMS_RECEIVED`.
2. Events are pushed to Flutter via `EventChannel` (`com.example.communication_super_app/sms_events`).
3. `NativeSmsService` (Dart) wraps the `EventChannel` stream. Call `initialize()` exactly once — a second call is a no-op (guarded by `_initialized`).
4. `SmsService.listenToIncomingSms()` subscribes to `NativeSmsService.onSmsReceived`, persists the message, shows a notification, and calls `onMessageReceived` callback → `MessageBloc.add(ReceiveMessage(...))`.
5. The listener is registered at most once per session (`_listening` guard). `MessageBloc` starts it on the first `LoadThreads` event.

**Sending:**
`SmsService.sendSms` → `NativeSmsService.sendSms` → `MethodChannel` (`com.example.communication_super_app/sms`) → `SmsHandler.kt.sendSms`. The native side performs pre-flight SIM/service checks before calling `SmsManager`. Error codes: `NO_SIM_CARD`, `NO_SERVICE`, `PERMISSION_DENIED`, `SMS_SEND_FAILED`.

**Import:**
`SmsService.importDeviceMessages` reads up to 500 inbox + 500 sent messages from the device via the `telephony` plugin. Runs once per app session (`_imported` static flag). Uses batch inserts with `ConflictAlgorithm.ignore`.

### MessageBloc state guards

- `LoadThreads` does **not** emit `MessageLoading` if the current state is already `ThreadsLoaded` or `MessagesLoaded` — this prevents the chat screen going blank when a background SMS triggers a thread refresh.
- `_cachedPhoneToName` is built once per session and reused by `_resolveContactNames` to enrich threads with device contact names without hitting the contact store on every tab switch.

### Authentication & app lock

- Auth type (PIN or pattern) and credentials are stored in `flutter_secure_storage`.
- `AppLockService` tracks the locked/unlocked state in memory.
- `AppLockWrapper` listens for `AppLifecycleState` changes and can re-lock the app on resume.

### RTL / Persian

All UI text is Persian. Wrap any new screen or dialog root with `Directionality(textDirection: TextDirection.rtl, ...)` or use `RtlAppBar`. The `PersianUtils` class and `AppConstants.persianNumbers` handle Persian digit conversion.
