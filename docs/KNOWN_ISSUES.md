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

### K2 — `notes` feature removed (resolved)
**Severity:** Low (cosmetic / vestigial).
**Detail:** the entire `notes` feature was unreachable dead code and has been
deleted, along with `AppConstants.notesTable` and its `CREATE TABLE`. The DB
version was bumped 8→9 and the `notes` table is dropped for existing installs
(`DROP TABLE IF EXISTS notes` in `_onUpgrade`).
**Fix:** done.

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

### K5 — Discontinued dependency: `telephony` 0.2.0 ✅ FIXED
**Severity:** Medium (supply-chain / future Android compatibility).
**Detail:** the discontinued `telephony` plugin powered SMS import and the
receive fallback; it would not receive fixes for future Android API levels.
**Fix (applied):** swapped to the maintained, API-compatible fork
**`another_telephony` `^0.4.0`**. The change is exactly two lines — the
`pubspec.yaml` dependency and the single import in
`lib/features/messages/services/sms_service.dart`
(`package:telephony/telephony.dart` → `package:another_telephony/telephony.dart`).
The fork is API-compatible (`Telephony`, `SmsMessage`, `SmsColumn`, `OrderBy`,
`Sort` are unchanged), so no other code changed.
**Verified:** `flutter pub get` resolves it (note: `flutter pub add` does a
broader pub.dev pre-scan that fails under this environment's restricted access —
editing `pubspec.yaml` directly and running `pub get` is the working path);
`flutter analyze` clean; 113 tests pass; **debug APK builds and runs on a
physical device (Samsung A33, Android 16) without crashing**.

---

### K6 — Several dependencies are major versions behind 🟡 PARTIALLY DONE
**Severity:** Low–Medium.
**Detail / status (probed 2026-06-30, one branch per package):**

- **`local_auth` 3.0.0 → 3.0.1** ✅ **done** (merged to main).
  Patch bump; the native `local_auth_android` is unchanged, so it's a pure
  Dart-wrapper update. analyze clean, 113 tests pass.
- **`flutter_secure_storage` 9.2.4 → 10.3.1** ⛔ **blocked.** v10 depends on a
  newer `flutter_secure_storage_windows` that is **not in the local pub cache**;
  fetching it fails with the pub.dev authorization error. (Editing `pubspec.yaml`
  by hand and running `pub get` instead of `pub add` only works when the *entire*
  transitive closure is already cacheable, which it isn't here.)
- **`flutter_local_notifications` 18 → 22** ⛔ **blocked.** v21+ pulls a newer
  `timezone` that is likewise uncached → same pub.dev auth failure.
- **`flutter_contacts` 1.1.9 → 2.2.2** ⏸️ **deferred (resolves, but a full API
  rewrite).** v2 is a ground-up rewrite by a new maintainer: `Contact` is
  immutable (build via one named constructor, not setters), the statics moved
  (`getContact`→`FlutterContacts.get`, `getContacts`→`getAll`,
  `contact.insert()`→`FlutterContacts.create`), labels are wrapped in
  `Label<T>`, `customLabel` is gone, and bool flags became a
  `Set<ContactProperty>`. ~35 compile errors across `contact_repository.dart`,
  `add_edit_contact_screen.dart`, `device_contact_detail_screen.dart`. Deferred
  because contacts CRUD **cannot be verified in this environment** (the app is
  PIN-locked and the contact-edit UI can't be driven headlessly), and 1.1.9 is
  **not** discontinued — so there is no urgency to ship an unverified rewrite.
  When tackled: do it on its own branch and manually QA add/edit/delete on a
  device before merging.

**Why the blocked ones can't proceed even with internet:** this environment's
pub.dev access rejects fetching any package version (incl. transitive platform
packages) not already in the local cache, regardless of connectivity.

---

### K7 — Low automated test coverage 🟡 IMPROVING
**Severity:** Medium (process risk).
**Detail:** coverage was near-zero (only `phone_normalizer_test.dart`). This pass
added BLoC tests for `DialerBloc`, `MessageBloc` (`_onReceiveMessage` +
`_onLoadThreads` guards), `CallLogBloc`, `FavoritesBloc`, `SettingsBloc`, plus
widget tests for the extracted message widgets, and repository tests against the
real schema on an in-memory `sqflite_common_ffi` database — enabled by the K9
constructor-injection fix and the `DatabaseHelper` testing hooks. Now covers all
stateful BLoCs and the favorites/blocked/messages/drafts repositories, plus the
presentation widgets extracted from the messages screens (app bars, composer,
option sheets), and the scheduled-send model/repository/bloc/list-screen. Total:
**450 passing** (was 138 at the review pass) — and the suite already paid for
itself by surfacing K10; later it pinned the device-traced call teardown
sequences (three `DISCONNECTED`s per hang-up, the first without a cause) that
«تماس مجدد خودکار» depends on. Still
missing: the SMS/call-log pipelines and full-shell widget tests
(`MainNavigation`).
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

---

### K11 — Scheduled send: background delivery ✅ IMPLEMENTED (PHASE 2, pending device QA)
**Severity:** Medium (functional).
**Where:** `android/.../scheduled/` (Kotlin) + `NativeScheduledSmsService` +
`ScheduledMessageBloc`.
**Phase 1 (foreground):** while the app runs, a periodic in-bloc `Timer` fires
`DeliverDueScheduled`, which sends due messages via `SmsService`.
**Phase 2 (background, added):** a native **AlarmManager** alarm is armed for the
soonest pending message (`ScheduledSmsScheduler`). When it fires — even with the
app killed — `ScheduledSmsAlarmReceiver` runs `ScheduledSmsWorker`, which opens
the `sqflite` DB **directly** (no Flutter engine), sends every due message with
`SmsManager`, advances/completes the row (recurrence logic mirrored in Kotlin),
and re-arms the alarm. `BootReceiver` re-arms after reboot / app update. The Dart
side calls `NativeScheduledSmsService.reschedule()` (MethodChannel
`…/scheduled_sms`) after every schedule change and on app start.
**Sync invariant:** the table/column names, enum string values, and recurrence
math are duplicated in `ScheduledSmsWorker.kt` — keep them in lock-step with
`scheduled_message_model.dart` when either changes.
**Jitter:** applied at alarm-arm time — `ScheduledSmsScheduler` fires the alarm
at a random point within the window *after* the nominal time, leaving
`scheduled_at` (the recurrence base) untouched so recurring messages don't drift.
It is per-alarm (based on the soonest pending message's window), not strictly
per-message. Foreground delivery still ignores jitter (sends as soon as due).
**Still to do:**
- Exact alarms use `USE_EXACT_ALARM`/`SCHEDULE_EXACT_ALARM`; on Android 12 if the
  user denies exact-alarm permission the scheduler falls back to an inexact
  (best-effort) alarm.
- **Device QA:** schedule a message ~2 min out, kill the app, confirm it sends;
  test a recurring one and a reboot.

---

### K12 — SMS send/receive broken on Android 13/14+ ✅ FIXED
**Severity:** High (core feature) — found via on-device logcat on Android 16.
**Three independent platform-API regressions in `SmsHandler.kt` / manifest:**

1. **Receive silently dropped.** The dynamic `SMS_RECEIVED` receiver was
   registered with `Context.RECEIVER_NOT_EXPORTED` on Android 13+ (TIRAMISU).
   `SMS_RECEIVED` is a *system* broadcast (different UID), so `NOT_EXPORTED`
   blocks it — no persist, no notification, no UI refresh. **Fix:** register that
   receiver `RECEIVER_EXPORTED`. (The sent/delivered receivers listen for the
   app's own actions and stay `NOT_EXPORTED`.)
2. **Send threw on Android 14+.** The sent/delivered status `PendingIntent`s were
   built from an *implicit* `Intent(ACTION)` + `FLAG_MUTABLE`. Android 14 (U /
   API 34)+ forbids that combination → `IllegalArgumentException` → the whole send
   failed with `SMS_SEND_FAILED`. **Fix:** use `FLAG_IMMUTABLE` and make the
   intents explicit via `setPackage(context.packageName)`.
3. **Stale manifest receiver.** The manifest still hardcoded
   `com.shounakmulay.telephony.sms.IncomingSmsReceiver`, which no longer exists
   after the `telephony` → `another_telephony` swap → `ClassNotFoundException`
   when the system delivered SMS to it. **Fix:** replaced it with the real
   `.IncomingSmsReceiver` (see K13).

**Also fixed (`message_bloc.dart`):** incoming-SMS threads showed the raw number
instead of the contact name because `_resolveContactNames` matched on raw digits
— an incoming E.164 address (`+989…`) never matched a contact saved as `09…`.
Now both sides are normalized with `PhoneNormalizer.toThreadId` (national `09…`).
**Verified on device (Android 16):** logcat shows `SMS sent successfully`,
`SMS delivered successfully`, and `SMS received from: +98…`.

---

### K13 — Background SMS notifications + live contact refresh ✅ ADDED (pending device QA)
**Notifications when the app is closed.** The live receive path
(`SmsHandler` dynamic receiver → EventChannel → Flutter) only exists while the
app process is alive, so a killed app posted nothing. Added a manifest-registered
`IncomingSmsReceiver` that, **only on a cold start** (guarded by
`SmsHandler.isDynamicReceiverActive` so it never double-handles a live app),
persists the SMS straight into the sqflite DB (`INSERT OR IGNORE`, matching the
Dart schema/enum strings + `PhoneNormalizer` thread-id) and posts a notification
natively via `NotificationCompat` (contact name resolved through
`ContactsContract.PhoneLookup`). *Verified: compiles, receiver registered
(priority 999), app boots clean. Real closed-app delivery is on-device QA.*

**Notification/thread contact name** now uses device contacts
(`ContactRepository.getDeviceContactName`, normalized match) instead of the empty
local table, so the saved name shows rather than `+98…`.

**Live device-contact refresh.** `ContactRepository`'s static cache was only
invalidated on the app's own CRUD, so a contact added in the phone's Contacts app
didn't appear until restart. `MainNavigation` now registers
`FlutterContacts.addListener` + an app-resume hook that force-refreshes the
contact list (`ContactBloc.RefreshContacts`) and re-resolves thread names
(`MessageBloc.RefreshContactNames`).
