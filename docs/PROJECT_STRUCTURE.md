# PROJECT STRUCTURE

The codebase is **feature-first**: cross-cutting code lives under `lib/core/`,
every user-facing capability is a folder under `lib/features/`, and the Android
side of each one sits under the same Kotlin package.

## Top-level

```
lib/
  main.dart                 Entry: flavor check, crash reporting, MaterialApp, the gates
  core/                     Cross-cutting, feature-agnostic code
  features/                 One folder per feature (below)
android/app/src/main/kotlin/com/example/communication_super_app/
                            Native side: SMS, calls, contacts, SIMs, crypto (below)
android/app/src/test/       JVM tests of the native code (crypto, wire format, key bank)
test/
  unit/                     Logic, BLoC and repository tests (in-memory SQLite)
  widget/                   Widget tests
tools/keybank/              Windows tool: key bank CLI + «پنل صدور هم‌رسان» (MSI)
scripts/                    Release builds, keystore backup
docs/                       This documentation (index: docs/README.md)
assets/fonts/               Vazirmatn
```

## `lib/core/`

```
core/
  bloc_providers/   AppBlocProviders — every BLoC, created once
  constants/        AppConstants — DB name/version, table names, storage keys
  database/         DatabaseHelper — the single main SQLite database (schema v1)
  edition/          AppEdition (build flavor), ActivationCode / ActivationTarget
  navigation/       MainNavigation (tabs), CallUiCoordinator, ReturnToCallBar
  services/         permissions, crash reporting, deep links, AppHandoff,
                    location, image picking, device-sync queue
  sim/              SimService / SimBloc / SimCard and the SIM widgets
  theme/            colors, dimensions, surface roles, ThemeBloc
  utils/            phone normalization, SearchText, Jalali dates, BLAKE3,
                    ScriptDirection, USSD, Persian digits
  widgets/          PermissionGate, DefaultAppGate, AppLockWrapper, shared rows,
                    avatars, selection bar, undo snack bar
```

## `lib/features/`

Every feature uses the same sub-layout — `bloc/ models/ repositories/ screens/`,
plus `services/` where it bridges to native code or orchestrates, and `widgets/`
or `screens/widgets/` for extracted widgets.

| Feature | What it is |
|---|---|
| `authentication` | App PIN / pattern, recovery code, app lock, biometric unlock |
| `call_history` | «اخیر» — the call log, mirrored from the device |
| `contacts` | The device address book: list, detail, edit, labels, merge, SIM contacts |
| `dialer` | Keypad, the call screens, speed dial, auto redial |
| `favorites` | «موردعلاقه‌ها» |
| `messages` | SMS inbox, conversation, composer, drafts, templates, scheduled and group SMS |
| `search` | Unified search across contacts, calls and messages |
| `settings` | Settings pages, blocked numbers |
| `edition` | Edition state and activation (`EditionBloc`, `OrganizationActivationGate`) |
| `secure` | The secure section: its PIN, vault, SQLCipher `secure.db` |
| `keybank` | «بانک کلید» — key files, trust anchors |
| `secure_sms` | «پیام‌های رمز» — encrypted SMS and groups |
| `hidden` | «دفترچه مخفی» — hidden contacts and their calls and SMS |
| `security` | Device check, intruder photos |

## Native side (`android/app/src/main/kotlin/com/example/communication_super_app/`)

```
MainActivity.kt           Channels, intents, window flags
SmsHandler.kt             SMS send / query channel
SmsDeliverReceiver.kt     SMS_DELIVER (default SMS app): writes the provider
IncomingSmsReceiver.kt    SMS_RECEIVED: persists while the app is dead, notifies
SmsNotifier.kt …          Incoming-SMS notifications and their actions
BlockedNumbers.kt         Native mirror of the block list
TemplateWire.kt           Template SMS wire format (mirror of the Dart model)
call/                     InCallService (default dialer), call rules, missed calls
calllog/                  Call-log sync
contacts/                 Contact extras, groups, links, SIM contacts
scheduled/                Scheduled SMS: alarm, worker, boot re-arm
sim/                      SIM registry and the one SIM rule for calls
edition/                  Device identity (activation)
secure/                   Keystore vault for the secure section
security/                 App lock, biometric gate, device check, intruder camera
hidden/                   Hidden-phonebook tags, sealed inbox, call-log sweep
smscrypto/                SMS encryption: handshake, ratchet, wire format, cover text
  keybank/                Key files, member certificates, authority (shared with tools/)
media/                    Contact photos
```

## Database

### Main database (`communication_app.db`, `DatabaseHelper`, version 1)

`contacts` · `messages` · `message_search` · `call_logs` · `favorites` ·
`blocked_numbers` · `archived_threads` · `pinned_threads` · `unread_marks` ·
`drafts` · `message_categories` · `message_templates` · `scheduled_messages` ·
`thread_sim` · `speed_dial` · `message_groups` · `message_group_members` ·
`message_group_targets` · `contact_name_cache` · `secure_queue` · `sealed_queue`

The invariants of each table are in `DEVELOPER_GUIDE.md` (Database) and the
area notes. Nothing secret is ever written here: Kotlin opens this database
while the app is dead, with no key. `secure_queue` and `sealed_queue` hold only
ciphertext waiting for the secure section.

### Secure database (`secure.db`, SQLCipher)

Opened only by `lib/features/secure/` with the vault key; holds encrypted
conversations, the key bank, hidden contacts and intruder photos. See
`architecture/editions.md`.

There are **no migrations** yet: both schemas are version 1 and nothing has
shipped. The first change after a release raises the version and adds an
`onUpgrade`.

## Naming conventions

- BLoC files are `<f>_bloc.dart`, `<f>_event.dart`, `<f>_state.dart` (or one file
  for a small bloc).
- A screen file is `<thing>_screen.dart` and exposes one public `…Screen`.
- Repositories end in `_repository.dart`; platform and plugin wrappers in
  `_service.dart`.
- Extracted widgets live in a `widgets/` folder next to the screens using them.

## Build and config files

- `pubspec.yaml` — dependencies; `default-flavor: commercial`.
- `android/app/build.gradle.kts` — the two flavors, the shared applicationId and
  signing key, the organization versionCode band.
- `analysis_options.yaml` — `flutter_lints`.
- `android/key.properties` and the keystore are **never** in git.
