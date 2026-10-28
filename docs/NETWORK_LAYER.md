# NETWORK LAYER

## TL;DR — there is no remote network layer

The app makes **no HTTP, REST or WebSocket calls to a backend** and has no API
client. All data is local to the phone; the only "network" is the carrier — SMS
and voice — which Android mediates. The single exception is optional crash
reporting (below), off unless compiled in **and** turned on by the user, and
compiled out of the organization edition entirely.

So this document describes the app's **data boundaries** and the contract at each.

## 1. The boundaries

```
 BLoCs ─▶ Repositories / services (Dart)
             │            │              │                 │
             ▼            ▼              ▼                 ▼
          SQLite     Platform        Device plugins    Key/value
       (main + the   channels        (contacts,        (SharedPreferences,
       SQLCipher     (Kotlin)        notifications,    secure storage)
       secure.db)                    permissions)
```

### A — SQLite

- **Main database** `communication_app.db` (`DatabaseHelper`, version 1). Read
  and written by Kotlin too, while the app is dead and with no key — so it holds
  nothing secret. Batch inserts into `messages` use `ConflictAlgorithm.ignore`
  against the unique content index `(phone_number, body, timestamp, type)`.
- **Secure database** `secure.db` (SQLCipher, `lib/features/secure/`, the only
  importer of `sqflite_sqlcipher`), opened with the vault key while the secure
  section is open.

### B — Platform channels (`com.example.communication_super_app/…`)

| Channel | Purpose |
|---|---|
| `sms`, `sms_events` | Send, query the provider, delete; incoming SMS pushed to Dart |
| `call`, `call_events` | The call lifecycle as the default dialer |
| `call_log`, `call_log_events` | Call-log reads and change notifications |
| `sim`, `sim_events` | SIM roster, defaults, the SIM rule for calls |
| `sim_contacts`, `contact_extras`, `contact_groups`, `contact_link` | The address book beyond what `flutter_contacts` offers |
| `scheduled_sms` | The native scheduled-SMS deliverer and its alarm |
| `blocked` | The phone-wide block list |
| `intents`, `media`, `location` | Deep links, contact photos, the location for «ارسال موقعیت» |
| `app_lock` | Biometric prompt, notification privacy, lock session |
| `device_identity` | The device code for activation |
| `secure_vault`, `key_file` | The secure section's Keystore vault, the key-file picker |
| `sms_crypto` | Stateless SMS crypto: handshake, encrypt/decrypt, cover text |
| `hidden` | Hidden-phonebook tags, sealed inbox, device check, intruder photos |

Error codes returned across a channel (for SMS send: `NO_SIM_CARD`,
`NO_SERVICE`, `PERMISSION_DENIED`, `SMS_SEND_FAILED`, `HIDDEN_NUMBER`) are a
**contract**: both sides change together. Files that mirror each other across the
boundary are listed in `DEVELOPER_GUIDE.md` («Kotlin/Dart mirrors»).

### C — Device plugins

| Plugin | Used by |
|---|---|
| `flutter_contacts` | `ContactRepository` — the device address book is the contact store |
| `permission_handler` | `PermissionService`, only behind `PermissionGate` |
| `flutter_local_notifications` | Notifications posted from Dart (most SMS notifications are native) |
| `flutter_secure_storage` | PIN hash, recovery code, activation code |
| `url_launcher`, `path_provider`, `package_info_plus`, `shared_preferences` | as named |

**No plugin may request a runtime permission itself** — that is why `call_log`,
`another_telephony`, `image_picker` and `image_cropper` were removed (see
`DEVELOPER_GUIDE.md`).

### D — Key/value

- `SharedPreferences`: theme, settings, small UI state.
- `flutter_secure_storage`: the salted, stretched PIN, the recovery-code hash,
  activation codes.

### The one outbound connection: crash reporting

`CrashReporting` (pure-Dart `sentry`) sends crash reports only when a DSN was
compiled in **and** the user turned «تشخیص خطا» on. Every string is redacted
(runs of 4+ digits replaced), no message content, no screenshots. The
organization build compiles it out (`CrashReporting.isAvailable`).

## 2. Resilience at the boundaries

- Start-up never waits on a failing boundary: notification init is best-effort,
  the gates render blank instead of a spinner, the inbox and «اخیر» paint from
  SQLite before the device answers.
- A refused permission leaves the rest usable; each screen says what is missing.
- Duplicate SMS (live receive and the later mirror-sync) collapse in the content
  index; native work that would block the main thread (ICC, call-log reads) runs
  on its own executor.

## 3. If a backend is ever added

Add a `core/network/` layer (a client, a typed result, DTO ↔ model mappers),
inject it into repositories and keep BLoCs unchanged; widgets never call the
network. Mind the organization edition: it is handed over on the promise that
nothing on it talks to a third-party server.
