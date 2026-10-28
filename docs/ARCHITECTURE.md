# ARCHITECTURE

> هم‌رسان — a Flutter Android SMS / phone app with a Persian (RTL) UI, in three
> editions: تجاری (commercial), بین‌سازمانی (inter-organizational) and سازمانی
> (organization).

The rules that hold everywhere are in `DEVELOPER_GUIDE.md`; each area has a note
under `architecture/`. This page is the overview.

## 1. Overview

A **feature-first, layered, single-module Flutter application** with a large
native Android half. There is no backend: data comes from

1. **SQLite** — the main database, and the SQLCipher `secure.db` of the secure
   section;
2. **platform channels** — Kotlin for SMS, calls, the call log, SIMs, the address
   book beyond the plugin, the Keystore vault and the SMS crypto;
3. **device plugins** — `flutter_contacts`, `permission_handler`,
   `flutter_secure_storage`, `flutter_local_notifications`.

State is **BLoC** only, every BLoC provided once at the top of the tree.

The app is the phone's **default SMS app and default dialer**: it owns the SMS
provider writes and every call screen. Most of the hard-won behaviour lives where
those roles meet the device — see `architecture/sms-role-and-sync.md` and
`architecture/dialer-and-calls.md`.

## 2. Start-up

```
main()
 ├─ AppEdition.verifyBuildFlavor()        unknown flavor → refuse to start
 └─ CrashReporting.runApp
     ├─ NotificationService().initialize()   best-effort
     └─ runApp(MyApp)
         └─ AppBlocProviders                  every BLoC
             └─ MaterialApp (theme, calendar)
                 ├─ builder: ReturnToCallBar → SecureSessionGuard → AppLockWrapper
                 └─ home: CallUiCoordinator           call screens surface over anything
                       └─ OrganizationActivationGate  organization APK: activation first
                           └─ AuthWrapperScreen        PIN setup / PIN entry
                               └─ PermissionGate        every runtime permission, batched
                                   └─ DefaultAppGate     the SMS and dialer roles
                                       └─ MainNavigation
```

- **`CallUiCoordinator`** sits above the auth flow so an incoming call is
  answerable on the PIN screen; the app lock is a route it can push over.
- **`OrganizationActivationGate`** keeps an organization APK closed until a code
  issued for that edition is entered (`architecture/editions.md`).
- **`PermissionGate`** is the only place a runtime permission is requested.
- **`MainNavigation`**: «اخیر» · «موردعلاقه‌ها» · «مخاطبین» · «پیام‌ها»; the
  keypad opens as a sheet. On launch it lands on the tab where something new
  happened (`DEVELOPER_GUIDE.md`).
- Nothing on the way in draws a spinner: the gates render blank, the inbox and
  «اخیر» paint from SQLite and are named from `contact_name_cache`.

## 3. Layering

```
features/<name>/
  screens/        widgets (+ widgets/ for extracted pieces)
  bloc/           events, states, bloc
  services/       native / plugin bridging and orchestration
  repositories/   data access — DatabaseHelper, SecureStore or a plugin
  models/         immutable models (Equatable)
```

```
Widget ──event──▶ BLoC ──▶ Repository / Service ──┬─▶ SQLite
                                                  ├─▶ platform channel ─▶ Kotlin
                                                  └─▶ plugin
```

A widget never touches a repository or a channel; a BLoC never builds UI.

## 4. Editions

One codebase, **two APKs** (Gradle flavors `commercial` and `organization`), one
applicationId and one signing key. The inter-organizational edition is the
commercial APK unlocked by an activation code. The organization APK has a
versionCode band two billion above the store build, so a store can never replace
it. Edition-specific code branches on compile-time constants
(`kOrganizationBuild`), so the other edition's code is absent, not just hidden.
Everything secure — the secure section, encrypted SMS and groups, the key bank,
the hidden phonebook, the device check, intruder photos, cover text — is in
`architecture/editions.md`.

## 5. The native bridges

- **SMS** — `SmsHandler` (send, provider queries), `SmsDeliverReceiver` (the
  default-SMS-app write), `IncomingSmsReceiver` (persists and notifies while the
  app is dead), native notifications. The inbox is a **mirror** of the device
  provider kept in step by `SmsService.syncDeviceMessages`.
- **Calls** — the app holds `ROLE_DIALER`; `CallInCallService` receives every
  call and the Flutter screens are the only call UI. Device-specific invariants
  (Samsung's placeholder calls, teardown paths, the keyguard) are in
  `architecture/dialer-and-calls.md`.
- **SMS crypto** — `smscrypto/` in Kotlin (Bouncy Castle): member certificates
  and a two-part handshake, a background ML-KEM-768 upgrade, a per-direction
  ratchet with AES-256-GCM, the `#E:` wire format, cover text. Stateless over the
  `sms_crypto` channel; state lives in `secure.db`. Pinned by golden vectors.
- **SIMs** — `SimRegistry` holds the one SIM rule for calls; Dart only asks it.

## 6. Permissions

Declared in `android/app/src/main/AndroidManifest.xml`; the runtime ones are
requested only by `PermissionGate` (SMS, phone and call log, contacts,
notifications) or, for the two optional ones, by the app itself at the moment
they are turned on (camera for intruder photos, location for «ارسال موقعیت») —
never by a plugin. Both flavors carry the
same manifest; an edition-only permission would go into a flavor manifest.

## 7. Where to add things

- **A screen for an existing feature:** `features/<f>/screens/`, RTL root, the
  existing BLoC.
- **Persisted data:** a table in `DatabaseHelper._createDB` (or `secure.db` if it
  is secret), a model and repository, a BLoC if it has interactive state.
- **Anything native:** check the mirrors list in `DEVELOPER_GUIDE.md` first.
- **Shared code:** `lib/core/` only when two features use it.

See `PROJECT_STRUCTURE.md` for the tree and `STATE_MANAGEMENT.md` for BLoC
conventions.
