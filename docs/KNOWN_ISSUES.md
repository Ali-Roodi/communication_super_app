# KNOWN ISSUES

Issues discovered during the architecture review. Each has a severity, the
evidence, and a suggested fix. None block the build (`flutter analyze` is clean);
these are correctness, maintainability, or dependency concerns.

---

### K10 — Unique message-content index was missing on fresh installs ✅ FIXED
**Severity:** Medium (functional — duplicate SMS rows on new installs).
**Where:** `lib/core/database/database_helper.dart` (`_createDB`).
**Detail:** the unique index `idx_messages_content_unique` on
`(phone_number, body, timestamp, type)` was only created by the v2→v3
`_onUpgrade` migration, **not** by `_createDB`. So a fresh install at the current
version lacked it, and `ConflictAlgorithm.ignore` on batch inserts did nothing —
the same SMS received live and then re-imported produced **two** rows. Only
databases upgraded through v3 had the documented dedup behavior.
**Surfaced by:** the new `MessageRepository` dedup test in
`test/unit/repositories_test.dart`.
**Fix (applied):** `_createDB` now also creates the unique content index, so
fresh and upgraded databases behave identically (matches the CLAUDE.md invariant).

---

### K1 — `CallLogService` phone-matching used two different normalizations ✅ FIXED
**Severity:** Medium (functional — some calls showed as "unknown" though the
contact existed).
**Where:** `lib/features/call_history/services/call_log_service.dart`.
**Detail:** the contact map is keyed with `PhoneNormalizer.toThreadId(c.phoneNumber)`
(national `09xxxxxxxxx`), but the enrichment lookup used the isolate's raw
digit-only `normalized` (`replaceAll([^\d])`, possibly `98…`), so the lookup
missed whenever the call log stored a different format than the contact.
**Fix (applied):** enrichment now keys the lookup with
`_normalizePhoneNumber(phoneNumber)` (= `PhoneNormalizer.toThreadId`), matching
how the map is built; the now-unused isolate `normalized` field was removed.

---

### K2 — `notes` feature removed; DB table retained
**Severity:** Low (cosmetic / vestigial).
**Detail:** the entire `notes` feature was unreachable dead code and has been
deleted. The `notes` SQLite table (and `AppConstants.notesTable`) are **kept**
to avoid a destructive migration on shipped databases (see DESIGN_DECISIONS D9).
**Fix:** none required. If a notes feature is rebuilt later, the table is ready;
otherwise drop it in a future migration only if data loss is acceptable.

---

### K3 — Non-Iranian numbers normalize weakly
**Severity:** Low.
**Where:** `PhoneNormalizer.toNational`.
**Detail:** the normalizer is tuned for Iranian mobile formats. Landlines, short
codes, and foreign numbers fall back to a cleaned digit string, so two formats
of the same foreign number may not merge into one thread.
**Fix:** acceptable for the target market; revisit if international use grows.

---

### K4 — No localization layer; Persian strings are inline literals
**Severity:** Low (maintainability).
**Detail:** all user-facing text is hard-coded Persian throughout widgets and
BLoC error mappers. There is no `l10n`/ARB setup, so strings can't be reused or
translated, and duplicates exist (e.g. several `'به‌زودی'`, `'حذف'`).
**Fix:** introduce Flutter localization (Roadmap P2-5).

---

### K5 — Discontinued dependency: `telephony` 0.2.0 ⛔ FIX BLOCKED (offline env)
**Severity:** Medium (supply-chain / future Android compatibility).
**Detail:** `flutter pub get` reports `telephony` as **discontinued**. It powers
SMS import and the receive fallback. It will not receive fixes for future
Android API levels.
**Recommended fix:** swap to the maintained API-compatible fork
**`another_telephony`** — only the import path changes
(`package:telephony/telephony.dart` → `package:another_telephony/telephony.dart`).
**Why not done here:** this environment's pub.dev access is restricted to
already-cached packages; `flutter pub add another_telephony` fails with
"Insufficient permissions to the resource at https://pub.dev". Run these where
pub.dev is reachable:
```bash
flutter pub remove telephony
flutter pub add another_telephony
# then update the single import in lib/features/messages/services/sms_service.dart
flutter analyze && flutter test
```
The fork is API-compatible, so no further code changes are expected.

---

### K6 — Several dependencies are major versions behind ⛔ FIX BLOCKED (offline env)
**Severity:** Low–Medium.
**Detail:** `flutter_contacts` (1.x vs 2.2.x), `flutter_local_notifications`
(18 vs 22), `local_auth`, `flutter_secure_storage`. Newer versions have API
changes and security/Android-13+ fixes.
**Why not done here:** the same restricted pub.dev access (see K5) prevents
fetching newer package versions — `flutter pub upgrade --major-versions` cannot
download anything not already cached. These must be upgraded **one at a time,
with a device build**, in an environment with full pub.dev access. The major
bumps (`flutter_contacts` 2.x, `flutter_local_notifications` 22) carry API
changes and should each be their own PR (Roadmap P3-7).

---

### K7 — Low automated test coverage 🟡 IMPROVING
**Severity:** Medium (process risk).
**Detail:** coverage was near-zero (only `phone_normalizer_test.dart`). This pass
added BLoC tests for `DialerBloc`, `MessageBloc` (`_onReceiveMessage` +
`_onLoadThreads` guards), `CallLogBloc`, `FavoritesBloc`, `SettingsBloc`, plus
widget tests for the extracted message widgets, and repository tests against the
real schema on an in-memory `sqflite_common_ffi` database — enabled by the K9
constructor-injection fix and the `DatabaseHelper` testing hooks. Now covers all
stateful BLoCs and the favorites/blocked/messages/drafts repositories. Total:
**102 passing** — and the suite already paid for itself by surfacing K10. Still
missing: the SMS/call-log pipelines and full-screen widget tests
(`ConversationScreen`, `MainNavigation`).
**Fix:** continue Roadmap P4.

---

### K8 — Dormant VoIP/in-call code path
**Severity:** Low (intentional, but a maintenance trap).
**Detail:** `IncomingCallScreen`, `InCallScreen`, the `MainNavigation`
`DialerBloc` listener, and the `call/` `ConnectionService` Kotlin stack are
fully wired but never fire under the current "Option A" cellular calling. A
maintainer may mistake them for live code.
**Fix:** keep, but the dormancy is documented here and in DESIGN_DECISIONS D3.

---

### K9 — `MessageBloc`/`CallLogBloc` self-constructed dependencies ✅ FIXED
**Severity:** Low (testability).
**Detail:** these BLoCs used to `new` up their repositories/services internally,
blocking mock-based unit tests.
**Fix (applied):** both now accept optional constructor parameters that default
to the real implementations (`MessageBloc({repository, smsService,
contactRepository})`, `CallLogBloc({service, repository})`), so production code is
unchanged while tests can inject mocks — see `test/unit/message_bloc_test.dart`.
