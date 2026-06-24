# PROJECT STRUCTURE

The codebase is **feature-first**: cross-cutting concerns live under `lib/core/`,
and every user-facing capability is a self-contained folder under
`lib/features/`.

## Top-level

```
lib/
  main.dart                 App entry, MaterialApp, theme wiring
  core/                     Cross-cutting, feature-agnostic code
  features/                 One folder per feature (see below)
android/app/src/main/kotlin/com/example/communication_super_app/
  MainActivity.kt
  SmsHandler.kt             SMS BroadcastReceiver + send MethodChannel
  call/                     ConnectionService-based call stack
test/
  unit/                     Logic, BLoC, and repository (in-memory DB) tests
  widget/                   Widget tests for extracted presentation widgets
docs/                       This documentation
assets/fonts/               Vazirmatn (Persian brand font)
```

## `lib/core/`

```
core/
  bloc_providers/app_bloc_providers.dart   MultiBlocProvider for all BLoCs
  constants/app_constants.dart             DB name/version, table + storage keys
  database/database_helper.dart            Singleton SQLite open + migrations
  navigation/main_navigation.dart          Bottom-nav shell, fade IndexedStack
  services/
    app_lock_service.dart                  In-memory lock state
    image_picker_service.dart              Contact avatar picking
    permission_service.dart                Batched runtime permissions
  theme/
    app_colors.dart  app_dimensions.dart  app_theme.dart  theme_bloc.dart
  utils/
    date_formatter.dart                    Persian date/time formatting
    persian_utils.dart                     Persian digit conversion
    phone_normalizer.dart                  Canonical 09xxxxxxxxx normalization
  widgets/
    app_lock_wrapper.dart  avatar_widget.dart  lock_button.dart
    permission_gate.dart   rtl_app_bar.dart
```

## `lib/features/`

Every feature uses the same sub-layout: `bloc/ models/ repositories/ screens/`
(plus `services/` where native bridging is needed, and `screens/widgets/` for
extracted leaf widgets).

```
features/
  authentication/    PIN/pattern setup + entry + app-lock screens
  messages/          SMS threads, conversation, drafts, templates, categories
    services/        native_sms_service · sms_service · notification_service
    screens/widgets/ message_bubble.dart · thread_tile.dart
  contacts/          device-contact list, add/edit, detail screens
  dialer/            keypad + call lifecycle
    services/        native_call_service
    widgets/         dialer_widgets.dart (keypad keys, number display, rows…)
  call_history/      recents list (call_log plugin → SQLite cache)
    services/        call_log_service
    screens/widgets/ call_detail_sheet · call_log_tile
  favorites/         starred numbers
  search/            cross-feature search (contacts + call logs)
  settings/          settings + blocked numbers
```

### Naming conventions

- BLoC triad files are always `<f>_bloc.dart`, `<f>_event.dart`,
  `<f>_state.dart`.
- A screen file is named `<thing>_screen.dart` and exposes a single public
  `…Screen` widget.
- Extracted presentational widgets live in a `widgets/` folder next to the
  screens that use them; public when referenced across files, private (`_Foo`)
  when used only within their own file.
- Repositories are suffixed `_repository.dart`; platform/plugin wrappers are
  suffixed `_service.dart`.

## Database tables (owned by `DatabaseHelper`, `databaseVersion = 7`)

| Table                | Key                      | Purpose |
|----------------------|--------------------------|---------|
| `contacts`           | `id` (TEXT)              | App-saved contacts (mostly superseded by device contacts) |
| `messages`           | `id` (TEXT)              | SMS, `thread_id` = normalized number |
| `call_logs`          | `id` (TEXT)              | Local cache of device call history |
| `favorites`          | `normalized` (UNIQUE)    | Starred numbers |
| `blocked_numbers`    | `normalized` (UNIQUE)    | Blocked numbers |
| `archived_threads`   | `thread_id`              | Archived conversation state |
| `pinned_threads`     | `thread_id`              | Pinned conversation state |
| `message_categories` | `id`                     | Draft labels |
| `drafts`             | `id`                     | Saved (unsent) drafts |
| `notes`              | `id`                     | **Unused** — feature removed; table kept for migration safety (see KNOWN_ISSUES) |

## Generated / config files (do not hand-edit casually)

- `pubspec.yaml` / `pubspec.lock` — dependencies.
- `analysis_options.yaml` — lint config (`flutter_lints`).
- `android/` Gradle + manifest — permissions and the default-SMS/dialer roles.
