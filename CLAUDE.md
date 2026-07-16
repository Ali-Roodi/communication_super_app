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

Features: `authentication`, `messages`, `contacts`, `dialer`, `call_history`.

### State management

All state is BLoC (`flutter_bloc`). BLoCs are provided globally in `AppBlocProviders` — do not create new `BlocProvider`s inside screens; use `context.read<XBloc>()` / `context.watch<XBloc>()`.

### Database

Single SQLite database (`communication_app.db`, version 11) managed by `DatabaseHelper` singleton (`lib/core/database/`). Tables: `contacts`, `messages`, `call_logs`, `favorites`, `blocked_numbers`, `archived_threads`, `pinned_threads`, `message_categories`, `drafts`, `scheduled_messages`. Constants in `AppConstants`.

**Schema invariants:**
- `messages.thread_id` is the digits-only normalized phone number.
- `messages` has a unique index on `(phone_number, body, timestamp, type)` (DB v3) — all batch inserts must use `ConflictAlgorithm.ignore` to silently skip duplicates.
- `messages.is_read` marks unread received messages; sent messages are always inserted as `is_read = 1`.
- `messages.device_sms_id` (DB v11) is the row id of the message inside the device SMS provider (`content://sms`). It is the key of the mirror-sync diff and of global deletes. Null means "no known provider row" (e.g. sent while the app wasn't the default SMS app) — such rows are never deleted by the sync.

Migrations live in `DatabaseHelper._onUpgrade`. When bumping `AppConstants.databaseVersion`, add a migration block there.

### Scheduled messages

Two deliverers exist:
- **Dart** — `ScheduledMessageBloc` ticks every 30 s and calls `ScheduledDeliveryService.deliverDue()`.
- **Native** — `ScheduledSmsWorker.processDue()` runs from an AlarmManager broadcast when the app is dead.

When the alarm fires and the Flutter engine is alive, `ScheduledSmsAlarmReceiver` hands the delivery *back to Dart* over `ScheduledSmsChannel` (`deliverDue`) instead of sending natively. This is load-bearing: the native worker writes straight to SQLite, so a native send while the app is running leaves `ScheduledMessageBloc` and `MessageBloc` stale — the chat keeps its scheduled ghost bubble and never shows the sent message. `MainActivity` publishes the channel in `configureFlutterEngine` and clears it in `onDestroy`.

Still, they coordinate through `ScheduledMessageRepository.claimDue(now, token)`: one atomic `UPDATE … SET status='sending', claim_token=?` stamps the due rows, and each deliverer only processes rows carrying its own token. **Never send a scheduled message without claiming it first.** A row stuck in `sending` past `ScheduledMessage.staleClaimTimeout` is released back to `pending`.

Other invariants:
- A failed send backs off (`next_attempt_at`) and retries; only after `ScheduledMessage.maxAttempts` does it become `failed`.
- `advanceAfterSend()` **skips** occurrences missed while the device was off — it never replays them.
- `ScheduledSmsWorker` (Kotlin) mirrors the recurrence, retry and claim logic of `scheduled_message_model.dart`. Change both together.
- The native worker also inserts the delivered message into `messages`, so a background-delivered SMS shows up in its chat.
- Every outgoing message persisted anywhere is published on the static `SmsService.onMessageSent` stream; `MessageBloc` subscribes and folds it into the open conversation (this is what re-renders the chat after a scheduled send).
- `DeliverDueScheduled` re-reads the table on **every** tick, even when it sent nothing — the native worker may have completed a row directly in SQLite. Without this the ghost bubble survives until the app restarts.

### SMS pipeline

**Receiving:**
1. `SmsHandler.kt` (Android) registers a `BroadcastReceiver` for `SMS_RECEIVED`.
2. Events are pushed to Flutter via `EventChannel` (`com.example.communication_super_app/sms_events`).
3. `NativeSmsService` (Dart) wraps the `EventChannel` stream. Call `initialize()` exactly once — a second call is a no-op (guarded by `_initialized`).
4. `SmsService.listenToIncomingSms()` subscribes to `NativeSmsService.onSmsReceived`, persists the message, shows a notification, and calls `onMessageReceived` callback → `MessageBloc.add(ReceiveMessage(...))`.
5. The listener is registered at most once per session (`_listening` guard). `MessageBloc` starts it on the first `LoadThreads` event.

**Sending:**
`SmsService.sendSms` → `NativeSmsService.sendSms` → `MethodChannel` (`com.example.communication_super_app/sms`) → `SmsHandler.kt.sendSms`. The native side performs pre-flight SIM/service checks before calling `SmsManager`. Error codes: `NO_SIM_CARD`, `NO_SERVICE`, `PERMISSION_DENIED`, `SMS_SEND_FAILED`.

### Default SMS app role & device sync

The app requests the **default-SMS-app role** (ROLE_SMS) — banner in the inbox (`DefaultSmsBanner`), request flow in `SmsHandler.requestDefaultSmsRole` (RoleManager on Q+, `ACTION_CHANGE_DEFAULT` before; result resolved in `MainActivity.onActivityResult`, trusting `isDefaultSmsApp()` over resultCode). Manifest declares the four role-required components: `SmsDeliverReceiver` (SMS_DELIVER), `MmsReceiver` (WAP_PUSH_DELIVER stub — MMS is dropped), the `SENDTO`/`SEND` intent-filter on MainActivity, and `HeadlessSmsSendService` (RESPOND_VIA_MESSAGE).

**Responsibility split while default (do not double-handle):**
- `SmsDeliverReceiver` ONLY writes the incoming SMS into `content://sms` (the system stops doing this for the role holder).
- App-side persist/notify/UI keeps flowing through `SMS_RECEIVED` (`SmsHandler` dynamic receiver when alive, `IncomingSmsReceiver` on cold start) exactly as before.
- Every successful send (composer + native scheduled worker) **writes through** to `content://sms/sent` (`writeSentToProvider`) — otherwise the sent SMS is invisible to every other SMS app. The returned provider id lands in `messages.device_sms_id`.

**Mirror-sync (`SmsService.syncDeviceMessages`)** replaced the old one-shot import. Runs once per session on `LoadThreads` and silently on resume (`SyncDeviceMessages` event, no loading state). Steps: backfill `device_sms_id` (numeric-id rows), reconcile the 500 most-recent inbox+sent rows via `MessageRepository.reconcileDeviceRows` (known-id skip → exact content match → **fuzzy ±2 min match** — needed because live-received rows store the SMS-PDU timestamp while the provider stores receive time → insert), then hard-delete local rows whose `device_sms_id` vanished from the (uncapped) provider id set.

**Deletes are global:** `MessageBloc` delete events go through `SmsService.deleteMessagesGlobally` / `deleteThreadGlobally` (provider rows first — by `device_sms_id`, falling back to body+timestamp±10 s match; thread delete matches addresses by last-10-digits in `SmsHandler.deleteSmsThreadFromProvider`), then the local store. Never delete local-only; the mirror-sync would just be out of sync with the phone.

**Call-log sync:** `CallLogSyncHandler.kt` registers a ContentObserver on `CallLog.Calls` and pushes debounced change events (`call_log_events` EventChannel) → `CallLogBloc` runs a silent `SyncCallLogs` (no flicker, keeps pagination). `CallLogService.syncFromDevice()` mirrors: upsert device rows, delete numeric-id local rows missing from the device. In-app deletes use `deleteCallLogsGlobally` (provider delete via `WRITE_CALL_LOG`, then local). `NativeCallLogService.initialize()` is re-invoked on `LoadCallLogs` because the first observer registration can predate the READ_CALL_LOG grant.

**Contacts:** all writes go straight to the device address book via `flutter_contacts` (`AddEditContactScreen`); there are deliberately NO create/update/delete bloc events. `ContactRepository.getContactByPhoneNumber` resolves against the device-contact cache (normalized-number match) — the local `contacts` table is legacy and nothing writes to it.

### Default dialer role & in-call UI

The app also requests the **default-dialer role** (ROLE_DIALER) — `CallHandler.requestDefaultDialerRole` (RoleManager Q+, `ACTION_CHANGE_DEFAULT_DIALER` before; resolved in `MainActivity.onActivityResult`). While the app holds the role, telecom binds `CallInCallService` and **this app is the ONLY call UI on the device**, incoming and outgoing:

- `CallInCallService.onCallAdded` registers a `Call.Callback` and mirrors telecom states into `CallEventStreamHandler` → `DialerBloc.callStatus` → `CallUiCoordinator` navigation. `stickyState` is replayed in `CallEventStreamHandler.onListen` so a cold-started engine never misses the ringing call.
- Incoming calls post a full-screen notification (`USE_FULL_SCREEN_INTENT`) with answer/decline actions (`CallActionReceiver`) — this is what launches the app when its process is dead.
- **`CallUiCoordinator` (main.dart, wraps `home`) sits ABOVE the auth flow deliberately**: an incoming call must surface over the PIN screen; only the call screens are exposed, the rest stays locked. Do not move call navigation back inside `MainNavigation`.
- `CallHandler` actions prefer `CallInCallService.currentCall` (telecom) and fall back to the legacy `CallConnection` (VoIP path). Mute/speaker go through `InCallService.setMuted`/`setAudioRoute` — AudioManager alone does not affect telecom-managed calls. DTMF uses `Call.playDtmfTone` (remote) plus a local ToneGenerator beep.
- **NEVER request ROLE_DIALER unless `CallInCallService` is declared and functional** — incoming calls would have no UI at all.

**First-entry role prompts** (`PermissionGate`): after the runtime permissions, the SMS-role dialog then the dialer-role dialog are each shown exactly once (SharedPreferences flags `default_sms_role_requested_v1` / `default_dialer_role_requested_v1`, set BEFORE the dialog). Never re-prompt automatically — Android permanently auto-denies a role after two refusals; later requests go through the inbox banner (SMS) or Settings → Default apps (`openDefaultAppsSettings`).

### SMS notifications (single native pipeline)

ALL incoming-SMS notifications are posted natively by `SmsNotifier` — from the live dynamic receiver (`SmsHandler`) and the cold-start `IncomingSmsReceiver` alike. The Dart `NotificationService` posts SMS notifications ONLY in the rare telephony-fallback path; never add a second Dart-side notification to the native event path (it would duplicate).

- Actions are fully native (`SmsNotificationActionReceiver`): inline reply via RemoteInput (sends with SmsManager + provider write-through + app-DB insert) and mark-read (direct DB update). They work with the app dead.
- Notifications are tagged with the threadId; opening a conversation calls `clearThreadNotifications` and `setVisibleThread` over the intents channel — `SmsNotifier` suppresses notifications for the visible thread while the activity is resumed.
- Tap deep-links: the launch intent carries a `threadId` extra → `DeepLinkService` (cold start: `consumeInitialThreadId` in MainNavigation; warm: `onNewIntent` → `openThread`). Registered post-auth so a tap never bypasses the app lock.
- Blocked numbers are enforced in BOTH receive paths natively (`BlockedNumbers.isBlocked` mirrors `PhoneNormalizer`) and in the Dart listeners; `SmsDeliverReceiver` also skips the provider write, and `CallInCallService` rejects ringing calls from blocked numbers before any UI. Missed calls post a native «تماس بی‌پاسخ» notification (default-dialer duty).

### Delivery status (bubble ticks)

`SmsService.sendSms` generates the message UUID BEFORE the native send and passes it as `trackingId`; the native sent/delivered PendingIntents carry it back through the SMS EventChannel as typed `{"type":"status"}` events (incoming SMS events carry `"type":"received"`). `SmsService` updates the DB row and broadcasts on the static `onMessageStatusChanged`; `MessageBloc.MessageStatusChanged` swaps the message in the open conversation in place (⏱ pending → ✓ sent → ✓✓ delivered / failed with retry).

### MessageBloc state guards

- `LoadThreads` does **not** emit `MessageLoading` if the current state is already `ThreadsLoaded` or `MessagesLoaded` — this prevents the chat screen going blank when a background SMS triggers a thread refresh.
- `_cachedPhoneToName` is built once per session and reused by `_resolveContactNames` to enrich threads with device contact names without hitting the contact store on every tab switch.

### Authentication & app lock

- Auth type (PIN or pattern) and credentials are stored in `flutter_secure_storage`.
- `AppLockService` tracks the locked/unlocked state in memory.
- `AppLockWrapper` listens for `AppLifecycleState` changes and can re-lock the app on resume.

### RTL / Persian

All UI text is Persian. Wrap any new screen or dialog root with `Directionality(textDirection: TextDirection.rtl, ...)` or use `RtlAppBar`. The `PersianUtils` class and `AppConstants.persianNumbers` handle Persian digit conversion.
