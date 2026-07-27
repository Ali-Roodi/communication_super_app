# ARCHITECTURE

> Communication Super App — internal name **هم‌رسان**.
> A Flutter Android SMS / phone "super-app" with a Persian (RTL) UI.

## 1. Overview

The app is a **feature-first, layered, single-module Flutter application**. There
is **no remote backend and no HTTP layer** — every piece of data comes from one
of three local sources:

1. **SQLite** (`sqflite`) — the app's own database (`communication_app.db`).
2. **Android platform channels** — native Kotlin code for SMS send/receive and
   the call lifecycle (`MethodChannel` + `EventChannel`).
3. **Device plugins** — `flutter_contacts`, `call_log`, `another_telephony`,
   `permission_handler`, `local_auth`, `flutter_secure_storage`.

State is managed exclusively with **BLoC** (`flutter_bloc`). All BLoCs are
provided once, globally, at the top of the widget tree.

## 2. Boot / startup flow

```
main()
 └─ NotificationService().initialize()      // best-effort, never crashes boot
 └─ SystemChrome.setPreferredOrientations() // portrait only
 └─ runApp(MyApp)
     └─ AppBlocProviders          (MultiBlocProvider — all BLoCs)
         └─ BlocBuilder<ThemeBloc>   → MaterialApp (theme + themeMode)
             └─ AppLockWrapper          (re-locks on resume)
                 └─ AuthWrapperScreen   (routes on AuthBloc state)
                     ├─ AuthNotSet       → PinSetupScreen
                     ├─ AuthSet          → PinAuthScreen
                     └─ AuthAuthenticated→ PermissionGate
                         └─ MainNavigation (bottom-nav shell)
```

- **`AuthWrapperScreen`** chooses the auth screen based on `AuthBloc` state.
- **`PermissionGate`** batches *all* runtime permission requests (SMS, Phone,
  Contacts, Notifications) **before** `MainNavigation` mounts. This is
  deliberate: several tab screens used to request permissions simultaneously
  from inside an `IndexedStack`, which crashed the app.
- **`MainNavigation`** is a 4-tab `NavigationBar` shell:
  `Recents (0) · Favorites (1) · Contacts (2) · Messages (3)`. The dialer is
  **not** a tab — it opens from a FAB as a `DraggableScrollableSheet`.

## 3. Layering

Each feature follows the same internal layering (top → bottom = UI → data):

```
features/<name>/
  screens/        Flutter widgets (+ screens/widgets/ for extracted leaf widgets)
  bloc/           <name>_bloc.dart · <name>_event.dart · <name>_state.dart
  services/       (messages, call_history, dialer only) native / plugin bridging
  repositories/   data access — wraps DatabaseHelper or a device plugin
  models/         immutable data models (Equatable)
```

**Dependency direction** is strictly downward:

```
Widget ──reads/adds──▶ BLoC ──awaits──▶ Repository ──┬─▶ DatabaseHelper (SQLite)
                          │                           └─▶ Service ─▶ Platform channel / plugin
                          └─ never touches the DB or platform channels directly
```

A widget never calls a repository or platform channel directly; it dispatches a
BLoC event. A BLoC never builds UI. A repository never imports `flutter_bloc`.

## 4. Module map

| Layer            | Lives in                          | Responsibility |
|------------------|-----------------------------------|----------------|
| App shell        | `lib/core/navigation`, `lib/main.dart` | Boot, tabs, lifecycle lock |
| Cross-cutting    | `lib/core/{theme,utils,widgets,constants,services}` | Theme tokens, RTL helpers, phone normalization, shared widgets |
| Persistence      | `lib/core/database/database_helper.dart` | Single SQLite database + migrations |
| Features         | `lib/features/*`                  | Authentication, messages, contacts, dialer, call_history, favorites, search, settings |
| Native (Android) | `android/.../kotlin/**`           | SMS BroadcastReceiver + ConnectionService call stack |

## 5. The two native bridges

### 5.1 SMS bridge (`messages/services`)
- **Receive:** `SmsHandler.kt` `BroadcastReceiver` → `EventChannel`
  (`…/sms_events`) → `NativeSmsService` → `SmsService.listenToIncomingSms()` →
  persist + notify + `MessageBloc.add(ReceiveMessage)`.
- **Send:** `SmsService.sendSms` → `NativeSmsService` → `MethodChannel`
  (`…/sms`) → `SmsHandler.sendSms` (pre-flight SIM/service checks).
- **Fallback:** if the native receiver fails to initialize, `SmsService` falls
  back to the `another_telephony` plugin (foreground-only, see code comments).

### 5.2 Call bridge (`dialer/services`)
- `NativeCallService` is a singleton wrapping a `MethodChannel` (`…/call`) and an
  `EventChannel` (`…/call_events`).
- **Option A (current):** outgoing calls hand off to the **native system
  dialer**; Android manages the in-call UI. `DialerBloc.callStatus` stays `idle`
  for cellular calls, so the in-app `IncomingCallScreen`/`InCallScreen` are
  effectively a **PHASE-2 VoIP path** that is wired but dormant.

### 5.3 Android permissions & manifest

`android/app/src/main/AndroidManifest.xml` declares every permission the native
bridges rely on. Runtime-dangerous ones are batch-requested by `PermissionGate`
before `MainNavigation` is built (see §3); the rest are install-time grants.

| Group         | Permissions |
| ------------- | ----------- |
| SMS           | `SEND_SMS`, `RECEIVE_SMS`, `READ_SMS` |
| Phone / calls | `CALL_PHONE`, `READ_PHONE_STATE`, `READ_CALL_LOG`, `WRITE_CALL_LOG`, `MANAGE_OWN_CALLS`, `PROCESS_OUTGOING_CALLS` |
| Contacts      | `READ_CONTACTS`, `WRITE_CONTACTS` |
| System        | `POST_NOTIFICATIONS`, `RECORD_AUDIO`, `VIBRATE`, `RECEIVE_BOOT_COMPLETED`, `USE_EXACT_ALARM`, `SCHEDULE_EXACT_ALARM` (background scheduled-SMS delivery) |

`SmsHandler` registers the `SMS_RECEIVED` `BroadcastReceiver`, and the
ConnectionService call stack relies on `MANAGE_OWN_CALLS` / `RECORD_AUDIO` for
the dormant PHASE-2 VoIP path (§5.2). When adding a native capability, declare
its permission here and add it to `PermissionService` if it is runtime-dangerous.

## 6. Key architectural decisions (see `DESIGN_DECISIONS.md`)

- **Global BLoC provisioning** — no per-screen providers; `context.read` only.
- **Phone number as the join key** — `messages.thread_id`, favorites, blocked
  numbers and contact matching are all keyed on the normalized national number
  (`09xxxxxxxxx`) produced by `PhoneNormalizer`, **not** on a contacts-table id,
  because contacts are read from the device, not stored as rows.
- **Session-scoped one-shot work** — SMS import, the SMS listener, and the
  phone→name cache each run once per app session, guarded by flags.

## 7. Where to add things

- **New screen for an existing feature:** `features/<f>/screens/`, wrap the root
  in `Directionality(rtl)` or use `RtlAppBar`; dispatch to the existing BLoC.
- **New persisted entity:** add a table in `DatabaseHelper`, bump
  `AppConstants.databaseVersion`, add an `_onUpgrade` migration block, add a
  model + repository, then a BLoC if it has interactive state.
- **New cross-feature widget/util:** put it under `lib/core/` only if ≥2 features
  use it; otherwise keep it local to the feature.

See `PROJECT_STRUCTURE.md` for the full tree and `STATE_MANAGEMENT.md` for BLoC
conventions.
