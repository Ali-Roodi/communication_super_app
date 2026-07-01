# REFACTORING ROADMAP

This file records refactors **done in this pass** and the prioritized backlog of
**remaining** work, with risk levels. Risk is about regression likelihood given
the near-zero automated test coverage.

## ✅ Done in this pass

| Change | Files | Risk taken | Verification |
|--------|-------|------------|--------------|
| Deleted the dead **notes** feature | `lib/features/notes/**`, removed `NoteBloc` from `AppBlocProviders` | Low (feature was unreachable — `NotesListScreen` had 0 references) | `flutter analyze` clean |
| Removed unused dependencies | `pubspec.yaml`: `go_router`, `shimmer` | None (never imported) | `flutter pub get` + analyze |
| Deleted dead route file + empty dir | `lib/core/routes/app_routes.dart`, empty `lib/core/router/` | None (self-referential only) | analyze |
| Extracted chat leaf widgets | `conversation_screen.dart` → `screens/widgets/message_bubble.dart` (`MessageBubble`, `MessageSendButton`) | Low (presentation-only, no logic moved) | analyze |
| Extracted dialer leaf widgets (656→160 lines) | `dialer_screen.dart` → `widgets/dialer_widgets.dart` | Low (presentation-only) | analyze |
| Fixed 2 lint infos surfaced by `dart format` | `permission_service.dart`, `conversation_screen.dart` (`curly_braces_in_flow_control_structures`) | None | analyze |
| Fixed call-log contact-matching bug (K1) | `call_log_service.dart` — unified phone normalization, removed dead isolate field | Low (correctness fix, no intended-behaviour change) | analyze |
| Decomposed `messages_list_screen` (640→571) | extracted `widgets/message_list_states.dart` (`MessagesEmptyState`, `MessagesNoResults`, `MessagesErrorState`, `ThreadSwipeBackground`) | Low (presentation-only) | analyze |
| Decomposed `add_edit_contact_screen` (630→579) | extracted `models/contact_form_entries.dart` (`PhoneEntry`/`EmailEntry`/label maps) + `widgets/contact_form_fields.dart` (`ContactFormField`/`AddMoreButton`) | Low (presentation/data extraction) | analyze |
| Constructor-injected dependencies into `MessageBloc` + `CallLogBloc` | both BLoCs now accept optional repos/services (default to real impls) | Low (backward-compatible) | analyze + tests |
| Added BLoC unit tests | `dialer_bloc_test.dart` (7), `message_bloc_test.dart` (4), `call_log_bloc_test.dart` (3), `favorites_bloc_test.dart` (4), `settings_bloc_test.dart` (5) | None | `flutter test` |
| Added widget tests | `test/widget/message_widgets_test.dart` (7: `MessageBubble` states + list state widgets) | None | `flutter test` |
| Added repository tests on a real in-memory schema | `test/unit/repositories_test.dart` (favorites, blocked, messages dedup/soft-delete/order, drafts + categories) via `sqflite_common_ffi`; added `@visibleForTesting` `databasePathOverride` + `resetForTesting()` hooks to `DatabaseHelper` | Low (test-only hooks) | `flutter test` |
| Added BLoC tests for the remaining BLoCs | `auth_bloc_test.dart` (5), `blocked_numbers_bloc_test.dart` (4), `contact_bloc_test.dart` (4) | None | `flutter test` |
| Fixed missing unique message-content index on fresh installs (K10) | `database_helper.dart` `_createDB` now creates `idx_messages_content_unique` (was migration-only) — surfaced by the new dedup test | Low (aligns fresh installs with the documented invariant) | `flutter test` |
| Added call-log repository, native channel-wrapper, and `ConversationScreen` widget tests | `repositories_test.dart` (call-logs), `native_services_test.dart`, `conversation_screen_test.dart` | None | `flutter test` |
| Added `ContactRepository` tests + extracted `MessageNavIcon` for the unread badge | `repositories_test.dart` (contacts CRUD + pure `filterContactsByPhoneDigits`); `core/navigation/widgets/message_nav_icon.dart` + `message_nav_icon_test.dart` | Low (presentation extraction) | `flutter test` |
| Added SMS dedup-window test via a `@visibleForTesting` seam on `SmsService` | `sms_service_dedup_test.dart` (covers DESIGN_DECISIONS D4) | Low (test-only seam) | `flutter test` |
| Decomposed the two remaining God screens | `messages_list_screen.dart` (571→444): app bars → `widgets/messages_app_bars.dart`, options sheet → `widgets/thread_options_sheet.dart`. `conversation_screen.dart` (854→552): app bars → `widgets/conversation_app_bars.dart`, composer + sticker panel → `widgets/message_composer.dart`, message-options + attachment sheets → `widgets/conversation_sheets.dart` | Low (presentation-only, callback-wired; the search/selection state stays in `State`) | analyze + `test/widget/decomposed_message_widgets_test.dart` (8) |
| `dart format` across `lib/` + `test/` | all | None | — |

Result: **`flutter analyze` → No issues found.** · **`flutter test` → 138/138 passing** (was 22).

## 🔜 Backlog (prioritized)

### P1 — High value, low/medium risk — ✅ DONE this pass
1. ✅ **Decomposed `messages_list_screen.dart`** (640→571) — empty/error/
   no-results states + swipe background extracted to
   `screens/widgets/message_list_states.dart`. The app bars + options sheet
   remain in `State` (heavily search/selection-coupled) — see "Remaining" below.
2. ✅ **Decomposed `add_edit_contact_screen.dart`** (630→579) — `PhoneEntry`/
   `EmailEntry` + label maps → `models/contact_form_entries.dart`; the reusable
   field + add-more button → `screens/widgets/contact_form_fields.dart`.
3. ✅ **Constructor-injected `MessageBloc` + `CallLogBloc`.** Both now accept
   optional dependencies (default to real impls), matching `DialerBloc`.

### P2 — Correctness / consistency
4. ~~Unify phone normalization in `CallLogService`.~~ ✅ **DONE** — see
   KNOWN_ISSUES K1.
5. **Introduce a localization layer (`l10n`).** ⚠️ **Not recommended at current
   size.** The app is single-locale (Persian); a full ARB layer adds indirection
   with no second language to justify it (cuts against the project's "no
   unnecessary abstraction" rule). Revisit only if a second locale is planned.
   If pursued anyway, it's low-risk but high-effort and mechanical.

### P3 — Dependency health

6. ✅ **Replaced the discontinued `telephony` plugin** with the API-compatible
   fork **`another_telephony` `^0.4.0`** (two-line change: `pubspec.yaml` + the
   import in `sms_service.dart`). Verified: analyze clean, 113 tests pass, debug
   APK builds and runs on a physical device. See KNOWN_ISSUES K5. *Note:
   `flutter pub add` fails under this environment's restricted pub.dev access,
   but editing `pubspec.yaml` and running `flutter pub get` resolves fine.*
7. **Upgrade outdated packages** — 🟡 partially done (one branch per package;
   see KNOWN_ISSUES K6 for detail):
   - ✅ `local_auth` 3.0.0→3.0.1 (native side unchanged, analyze clean, 113
     tests pass).
   - ⛔ `flutter_secure_storage` 9→10 and `flutter_local_notifications` 18→22 —
     blocked here: their newer transitive platform packages
     (`flutter_secure_storage_windows`, `timezone`) aren't cached and can't be
     fetched.
   - ⏸️ `flutter_contacts` 1→2.2.2 — resolves, but v2 is a full API rewrite;
     deferred (contacts CRUD can't be device-verified here and 1.1.9 isn't
     discontinued). Do it on its own branch with manual QA.

### P4 — Test coverage (enabler for everything above) — 🟡 IN PROGRESS
8. ✅ **BLoC unit tests** — covered: `DialerBloc` keypad + call lifecycle;
   `MessageBloc` `_onReceiveMessage` guards + `_onLoadThreads` no-flash guard;
   `CallLogBloc` pagination; `FavoritesBloc` load/add/remove + empty-number
   no-op; `SettingsBloc` defaults, bool toggle, the caller-ID→spam-filter
   dependency, and quick-reply bounds; `AuthBloc`, `BlockedNumbersBloc`,
   `ContactBloc`. Plus **repository tests** (favorites, blocked, messages,
   drafts, call-logs) on a real in-memory `sqflite_common_ffi` schema, and
   **native channel-wrapper tests** (`NativeCallService`,
   `NativeSmsService.sendSms`) via a mock `MethodChannel`; plus
   `ContactRepository` local-table CRUD and the pure
   `filterContactsByPhoneDigits`; and the `SmsService` in-memory dedup window
   (via a `@visibleForTesting` seam). (105 tests at that point — the dedup test surfaced
   and fixed K10.)
   **Still to add:** the SMS receive/import *wiring* (BroadcastReceiver →
   EventChannel → persist) needs a device/integration test; `ContactRepository`'s
   device-contact path (`getDeviceContacts`) needs a `flutter_contacts` seam.
9. ✅ **Widget tests** — extracted presentation widgets (`MessageBubble`
   states, `MessagesEmptyState/NoResults/ErrorState` incl. retry),
   `ConversationScreen` (one bubble per message, empty placeholder, day-separator
   chips), and the `MainNavigation` unread badge via the extracted
   `MessageNavIcon` (count, "99+" cap, filled/outline icon).
   **Still avoided:** full-shell `MainNavigation` pumping — its IndexedStack
   mounts every tab screen, which hits repositories/plugins at mount.

### Remaining screen decomposition — ✅ DONE this pass
- `messages_list_screen.dart` — the three app bars and the thread-options bottom
  sheet were extracted to `widgets/messages_app_bars.dart` (three
  `PreferredSizeWidget`s) and `widgets/thread_options_sheet.dart`. The screen
  keeps the search/multi-select `State` and passes callbacks down (571→444).
- `conversation_screen.dart` — the two app bars, the composer + sticker panel,
  and the message-options/attachment sheets were extracted to
  `widgets/conversation_app_bars.dart`, `widgets/message_composer.dart`, and
  `widgets/conversation_sheets.dart`. The composer is stateless and reads the
  parent-owned controller, so behaviour is unchanged (854→552).
- Covered by `test/widget/decomposed_message_widgets_test.dart` (composer
  send/segment-counter/stickers, the selection & conversation app bars, and the
  two option sheets).

## Refactoring rules for this repo

- **No business-logic change without a documented reason** (see the user
  constraints and `DESIGN_DECISIONS.md`).
- Extract **presentation** first; defer `State`-coupled logic until tests exist.
- Run `flutter analyze` after every extraction; keep it at **zero issues**.
- Keep files focused; prefer many small `widgets/` files over one God file, but
  do **not** create abstraction layers (interfaces/use-cases) the app size
  doesn't justify.
