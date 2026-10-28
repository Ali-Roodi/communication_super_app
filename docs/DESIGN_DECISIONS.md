# DESIGN DECISIONS

Each entry records a decision, the reasoning, and the trade-off accepted. These
are the choices that are **non-obvious from the code** and should not be reversed
without understanding why they exist.

---

### D1 — BLoC, provided globally, no per-screen providers
**Decision:** every BLoC is created once in `AppBlocProviders`; screens use
`context.read/watch`.
**Why:** the same state (unread counts, contacts cache, settings) is needed
across multiple tabs that stay mounted in an `IndexedStack`. Per-screen
providers would create/destroy state on every tab switch.
**Trade-off:** all BLoCs live for the whole app session (memory), and you cannot
scope a BLoC to a sub-tree. Acceptable for an app of this size.

---

### D2 — Phone number (normalized) is the universal join key
**Decision:** `messages.thread_id`, `favorites.normalized`,
`blocked_numbers.normalized` and contact matching all key on the national
`09xxxxxxxxx` form from `PhoneNormalizer`, not on a `contacts.id`.
**Why:** contacts are read from the **device** (`flutter_contacts`), not stored
as app rows, so there is no stable FK to join on. The same number arrives in
many formats (`+98…`, `0098…`, `9…`); normalizing prevents duplicate threads.
**Trade-off:** numbers that genuinely differ only by formatting are merged
(desired); non-Iranian numbers fall back to a digits-only string and may match
less precisely. See `KNOWN_ISSUES` K6.

---

### D3 — The app is the default dialer (supersedes the earlier "Option A")
**Decision:** the app requests `ROLE_DIALER`; `CallInCallService` receives every
cellular call from telecom and the Flutter `IncomingCallScreen`/`InCallScreen`
are the only call UI. The self-managed `ConnectionService` path stays as dormant
VoIP scaffolding.
**Why:** the hand-off to the system dialer meant no lock-screen answer, no
call-waiting UI and no per-call SIM choice of our own; the mentor's device tests
needed all three. The invariants that keep it working on real phones (Samsung's
STATE_NEW placeholders, the four teardown paths, the keyguard rules) are in
`docs/architecture/dialer-and-calls.md`.
**Trade-off:** the call path is the most device-fragile code in the app and is
verified by hand on the device, not by instrumentation tests.

---

### D3a — Auto redial only for a call that never connected
**Decision:** «تماس مجدد خودکار» retries an outgoing call only when telecom
says it never connected and ended `busy`/`remote`/`error`; a call that went
active — however short — is never redialled, and the count is a setting
(default off, 3 attempts, 5 s visible countdown with «لغو»).
**Why:** from inside the app a carrier's "subscriber not answering"
announcement is indistinguishable from a person picking up and saying "call me
later"; any duration threshold would redial real conversations. A phone that
dials by itself when it should not is worse than one that does not when it
could have.
**Trade-off:** a carrier that answers a busy line with a *connected*
announcement is not covered. Irancell reports busy as `DisconnectCause.BUSY`
(486) without connecting, verified on the device.

---

### D4 — SMS dedup at two levels
**Decision:** (1) a DB unique index on
`(phone_number, body, timestamp, type)` with `ConflictAlgorithm.ignore`, and
(2) a 5-second in-memory hash window in `SmsService`.
**Why:** the same SMS can arrive twice — once live via the BroadcastReceiver
(UUID id) and once via device import (different id). The content index collapses
them; the in-memory window stops rapid double-delivery before it hits the DB.
**Trade-off:** two legitimately identical messages sent in the same second to
the same number collapse to one. Extremely rare; accepted.

---

### D5 — The inbox is a mirror of the device, kept in step cheaply
**Decision:** the full device mirror-sync and the SMS listener registration run
once per session; resumes run a throttled sync (2 min), a delta call-log sync and
an address-book re-read at most every 10 min. The first paint comes from SQLite,
named from `contact_name_cache`.
**Why:** a full read of the provider or the address book is seconds on a real
phone; doing it on every resume or before every paint was the reported
«هر بار ۲ ثانیه لودینگ».
**Trade-off:** a change made on the device by another app can take until the
next throttled sync to show. See `architecture/sms-role-and-sync.md` and
`PERFORMANCE_NOTES.md`.

---

### D6 — Batched permission requests before the shell mounts
**Decision:** `PermissionGate` requests SMS/Phone/Contacts/Notifications
sequentially before `MainNavigation` is built.
**Why:** multiple `IndexedStack` children requesting permissions at once crashed
the app.
**Trade-off:** the user sees a short gate screen on first launch before the UI.

---

### D7 — Heavy mapping on a background isolate
**Decision:** `CallLogService` serializes raw call-log entries and maps them in
`Isolate.run`, then enriches with contacts on the main isolate.
**Why:** devices with thousands of call entries froze the UI during mapping.
**Trade-off:** a serialize/deserialize copy across the isolate boundary; cheaper
than the jank it removes.

---

### D8 — RTL/Persian everywhere
**Decision:** all UI is Persian; screens wrap their root in
`Directionality(rtl)` or use `RtlAppBar`; digits go through `PersianUtils`.
Brand font is **Vazirmatn**.
**Why:** the product is Persian-first (internal name هم‌رسان).
**Trade-off:** every new screen must remember the RTL wrapper; there is no
localization (l10n) layer — strings are inline Persian literals (see
`KNOWN_ISSUES` K7).

---

### D9 — One main database and one secure database, no migrations yet
**Decision:** the main database (`DatabaseHelper`) and the SQLCipher
`secure.db` are each one schema at version 1. Nothing has shipped, so a schema
change edits `_createDB` / `_onCreate` and the test phones are reinstalled; no
code handles data an earlier build wrote.
**Why:** 26 migrations had piled up for data that existed only on development
phones; each was code to read, test and get wrong.
**Trade-off:** none until the first release — from then on, every change raises
the version and adds an `onUpgrade`.

---

### D10 — Refactor by safe widget extraction, not rewrite
**Decision:** large screens are reduced by extracting presentation-only widgets
into `widgets/` files, with no change to business logic or BLoC contracts.
**Why:** behaviour on real phones is the hard part of this app and much of it is
verified by hand; a rewrite would re-open what is already settled.
**Trade-off:** some large `State` classes remain. The finished refactoring pass
is in `archive/REFACTORING_ROADMAP.md`.

---

### D11 — Two APKs, one applicationId, one signing key
**Decision:** the commercial and organization editions are Gradle flavors of one
codebase with the same package and key; the inter-organizational edition is the
commercial APK unlocked by an activation code. The organization versionCode is
`2_000_000_000 + N`.
**Why:** a store decides «نصب است» by package name, so every edition must share
it; the versionCode band is then what keeps a store from ever "updating" an
organization phone to the commercial build.
**Trade-off:** once the organization APK is on a phone, the commercial one cannot
be installed over it without an uninstall. See `architecture/editions.md`.

---

### D12 — Nothing secret outside the secure section
**Decision:** secret data lives only in the SQLCipher `secure.db`, opened with a
Keystore-bound key while the section is open. An encrypted SMS never enters
`content://sms` or `messages`; a hidden contact leaves no trace outside the
section.
**Why:** the main database is opened by Kotlin while the app is dead, with no
key, and the SMS provider is readable by other apps.
**Trade-off:** encrypted messages are read only inside the section, behind its
own PIN.

---

### D13 — SMS encryption: certificate handshake now, post-quantum upgrade after
**Decision:** a session starts with a two-part classical handshake authenticated
by member certificates from the key bank, then upgrades to ML-KEM-768 in the
background; messages use a per-direction ratchet with AES-256-GCM.
**Why:** the full post-quantum handshake costs about ten SMS parts before the
first message; the upgrade makes the conversation post-quantum seconds later
without the user waiting.
**Trade-off:** the first messages of a session are protected classically until
the upgrade lands. The wire format is pinned by golden vectors.

---

### D14 — Only `PermissionGate` asks for permissions
**Decision:** no plugin in this app may request a runtime permission.
**Why:** these plugins keep a single `MethodChannel.Result`; two overlapping
requests crash the process (`Reply already submitted`), and a plugin's own
dialog double-asks.
**Trade-off:** `call_log`, `another_telephony`, `image_picker` and
`image_cropper` were replaced by native code of our own.
