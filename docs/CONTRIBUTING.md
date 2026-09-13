# CONTRIBUTING

Guidelines for working in this repository. Read `ARCHITECTURE.md` and
`STATE_MANAGEMENT.md` first.

## Setup

```bash
flutter pub get
flutter run            # debug on a connected device/emulator
```
Android only (uses SMS/call platform channels). A physical device is recommended
for SMS/call features.

## Everyday commands

```bash
flutter analyze        # must be ZERO issues before committing
dart format lib test   # format before committing
flutter test           # run unit + widget tests (450 currently)
flutter test test/unit/phone_normalizer_test.dart   # single file
flutter build apk --release
# Device diagnostics that are OFF in a store build:
flutter build apk --release --dart-define=CARET_TRACE=true   # one `[caret]` logcat line per caret move
adb logcat -s flutter | grep -E '\[caret\]|\[redial\]'      # `[redial]` prints every DISCONNECTED verdict
```

### Test layout & harness
- `test/unit/` — pure logic + BLoC tests (`bloc_test` + `mocktail`). BLoCs that
  take constructor dependencies (`DialerBloc`, `MessageBloc`, `CallLogBloc`,
  `FavoritesBloc`) are tested with mocks; `SettingsBloc` uses
  `SharedPreferences.setMockInitialValues({})`.
- `test/widget/` — widget tests for extracted presentation widgets.
- **Repository tests** run the real schema/migrations on an in-memory database:
  call `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;` then set
  `DatabaseHelper.databasePathOverride = inMemoryDatabasePath` and
  `DatabaseHelper.resetForTesting()` between tests for isolation
  (see `test/unit/repositories_test.dart`).

## Definition of done

- [ ] `flutter analyze` → **No issues found.**
- [ ] `dart format lib` produces no diff.
- [ ] New/changed behaviour has a test where practical (`bloc_test`/`mocktail`
      are available).
- [ ] No new business-logic change without a note in `DESIGN_DECISIONS.md` or
      the PR description.

## Code conventions

### Architecture
- Respect the dependency direction: **Widget → BLoC → Repository → boundary**.
  Widgets never touch SQLite, plugins, or platform channels directly.
- **Do not** add a `BlocProvider` inside a screen. Register BLoCs in
  `core/bloc_providers/app_bloc_providers.dart` and use `context.read/watch`.
- Prefer **constructor injection** of repositories/services into BLoCs (testable).
- Don't introduce abstraction layers (use-cases, interfaces, DI containers) the
  app size doesn't justify. Simplicity and readability beat architectural purity
  here.

### Files & widgets
- One feature = one folder under `lib/features/` with `bloc/ models/
  repositories/ screens/` (+ `services/` if it bridges native/plugins).
- Keep screen files focused. Extract presentation-only widgets into a `widgets/`
  folder next to the screen. Make them **public** if used across files, private
  (`_Foo`) if local. Avoid God files (>~400 lines is a smell).
- Models extend `Equatable` and are immutable (`copyWith` for updates).

### RTL / Persian (mandatory)
- All user-facing text is Persian. Wrap any new screen/dialog root in
  `Directionality(textDirection: TextDirection.rtl, …)` or use `RtlAppBar`.
- Convert digits for display with `PersianUtils`; never show ASCII digits in UI.
- Normalize phone numbers through `PhoneNormalizer` — never hand-roll digit
  stripping for thread IDs / matching keys.

### Database changes
1. Add/alter the table in `DatabaseHelper` (`_createDB` for fresh installs).
2. Bump `AppConstants.databaseVersion`.
3. Add an **additive** `_onUpgrade` block for the new version (never drop data on
   upgrade — see `DESIGN_DECISIONS.md` D9).
4. All `messages` batch inserts use `ConflictAlgorithm.ignore`.

### State guards
Several BLoC behaviours protect the UX (no flash-to-loading on background
refresh, conversation stays put on cross-thread messages, optimistic call
teardown). They are documented in `STATE_MANAGEMENT.md` §3 — **don't remove them
as "redundant".**

## Commits & PRs

- Small, focused commits. Conventional-commit prefixes are used in history
  (`feat:`, `fix:`, `refactor:`).
- A PR that refactors should state: what moved, that behaviour is unchanged, and
  the `flutter analyze` result.
- High-risk changes (SMS pipeline, DB migrations, dependency upgrades) get their
  own PR and a manual test note.

## Native (Android) changes

- SMS: `android/.../SmsHandler.kt` + channels `…/sms`, `…/sms_events`.
- Calls: `android/.../call/**` + channels `…/call`, `…/call_events`.
- The Dart error-code contract (`NO_SIM_CARD`, `NO_SERVICE`, …) is shared with
  Kotlin — change both sides together (see `NETWORK_LAYER.md` §1 Boundary B).
