# NETWORK LAYER

## TL;DR — there is no remote network layer

This application makes **no HTTP/REST/GraphQL/WebSocket calls** and ships **no
API client, DTO, or serialization layer**. There is no `dio`/`http` dependency
and no backend. All data is **local to the device**. "Network", in the cellular
sense, only appears as SMS/voice carrier connectivity, which is mediated by
Android, not by app code.

This document therefore describes the app's **external data boundaries** — the
substitute for a network layer — and the contracts at each boundary.

## 1. The four data boundaries

```
                ┌──────────────────────────────────────────┐
   BLoCs ──────▶│ Repositories  (Dart, lib/features/*/repos)│
                └───────┬─────────────┬─────────────┬───────┘
                        ▼             ▼             ▼
                 ┌────────────┐ ┌───────────┐ ┌──────────────────┐
                 │  SQLite    │ │  Platform │ │  Device plugins   │
                 │ (sqflite)  │ │  channels │ │ contacts/call_log │
                 └────────────┘ │ (Kotlin)  │ │ telephony/auth    │
                                └───────────┘ └──────────────────┘
```

### Boundary A — SQLite (`DatabaseHelper`)
- Single database `communication_app.db`, version 7, opened lazily by a
  singleton.
- Repositories own all SQL. Schema and migrations live in `DatabaseHelper`.
- **Invariant:** every batch insert into `messages` uses
  `ConflictAlgorithm.ignore` against the unique content index
  `(phone_number, body, timestamp, type)` so live-received and later-imported
  copies of the same SMS collapse to one row.

### Boundary B — Android platform channels (the closest thing to a "network API")
Two named channels, each with a request side (`MethodChannel`) and, where
relevant, a push side (`EventChannel`):

| Channel name (`com.example.communication_super_app/…`) | Dart wrapper | Direction | Payload contract |
|---|---|---|---|
| `…/sms`         | `NativeSmsService` | Dart→native | `sendSms(phoneNumber, message)` → `{success, timestamp}` |
| `…/sms_events`  | `NativeSmsService` | native→Dart | `SmsReceivedEvent{address, body, timestamp}` |
| `…/call`        | `NativeCallService`| Dart→native | `makeCall/endCall/answer/reject/hold/mute/setSpeakerphone/sendDtmf/isInCall` |
| `…/call_events` | `NativeCallService`| native→Dart | `{event, phone, direction}` mapped to `NativeCallEvent` |

**Error contract (SMS send):** the native side returns typed `PlatformException`
codes — `NO_SIM_CARD`, `NO_SERVICE`, `PERMISSION_DENIED`, `SMS_SEND_FAILED` —
which `SmsService` forwards and `MessageBloc._localizedSendError` maps to Persian
user messages. **Treat these codes as a stable contract**; both sides must change
together.

### Boundary C — Device plugins
| Plugin | Used by | Notes |
|--------|---------|-------|
| `telephony` (**discontinued**) | `SmsService.importDeviceMessages` + receive fallback | Import is capped at 500 inbox + 500 sent to stay under the Binder transaction limit. |
| `call_log` | `CallLogService` | Read device call history; mapping runs on a background `Isolate`. |
| `flutter_contacts` | `ContactRepository` | Device contacts (the real contact store; the `contacts` SQLite table is largely vestigial). |
| `permission_handler` | `PermissionService` | Batched at `PermissionGate`. |
| `local_auth`, `flutter_secure_storage` | `authentication` | Credentials + biometric. |
| `flutter_local_notifications` | `NotificationService` | Incoming-SMS notifications. |

### Boundary D — Key/value (`SharedPreferences` + `flutter_secure_storage`)
- `SharedPreferences`: theme mode, settings flags, `sms_imported_v1`.
- `flutter_secure_storage`: PIN/pattern + auth type (never `SharedPreferences`).

## 2. Resilience patterns at the boundaries

- **Best-effort init:** `NotificationService().initialize()` is wrapped in
  try/catch in `main()` so a notification-channel failure never blocks boot.
- **Graceful permission denial:** `MessageBloc` shows local messages (or a
  localized error if empty) when SMS import fails.
- **Native→plugin fallback:** if the native SMS receiver can't initialize,
  `SmsService` falls back to the `telephony` listener (foreground-only).
- **De-duplication windows:** a 5-second in-memory hash set drops duplicate
  incoming SMS in addition to the DB unique index.

## 3. If a real backend is ever added

Introduce a `core/network/` layer (an `http`/`dio` client + typed
`Result`/`Either` error type + DTO↔model mappers), inject the client into
repositories, and keep BLoCs unchanged. Do **not** let widgets call the network
directly — preserve the `Widget → BLoC → Repository → boundary` direction
documented in `ARCHITECTURE.md`.
