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
less precisely. See `KNOWN_ISSUES` K3.

---

### D3 — Cellular calling via the native system dialer ("Option A")
**Decision:** outgoing calls are handed to Android's system dialer; the in-app
`IncomingCallScreen`/`InCallScreen` + `ConnectionService` stack are built but
dormant.
**Why:** a full self-managed `ConnectionService` call UI is complex and
device-fragile. Handing off is reliable and ships now.
**Trade-off:** no in-app call screen for cellular calls; `DialerBloc.callStatus`
stays `idle`. The dormant VoIP path is intentional PHASE-2 scaffolding.

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

### D5 — One-shot, session-scoped heavy work
**Decision:** device-SMS import, the SMS listener registration, and the
phone→name map each run once per session (flags / `SharedPreferences`).
**Why:** these are expensive (Binder payloads, full contact fetch). Re-running
on every tab switch or resume caused multi-second jank.
**Trade-off:** new device-side SMS/contacts during a session aren't picked up
until a forced refresh. Acceptable; the app is the SMS source of truth while
running.

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
`KNOWN_ISSUES` K4).

---

### D9 — Single SQLite database, migration-only schema changes
**Decision:** one DB file, version-bumped with additive `_onUpgrade` blocks;
tables for removed features are **kept**, not dropped.
**Why:** dropping tables/columns on a shipped DB risks data loss and complex
down-migrations. Additive migrations are safe.
**Trade-off:** vestigial tables may linger. Exception: the unused `notes` table
(never written to) was dropped in the v8→v9 migration since removing it is
data-loss-free (`DROP TABLE IF EXISTS notes`).

---

### D10 — Refactor by safe widget extraction, not rewrite
**Decision (this pass):** large screen files were reduced by extracting
**presentation-only leaf widgets** into `widgets/` files, with no business-logic
or BLoC-contract changes, verified by `flutter analyze` after each step.
**Why:** the project has near-zero test coverage; behavioural rewrites would be
unverifiable and risky.
**Trade-off:** some large `State` classes (form builders, list screens) remain
big; their decomposition is deferred to `REFACTORING_ROADMAP.md`.
