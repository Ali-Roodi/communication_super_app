# STATE MANAGEMENT

The app uses **`flutter_bloc`** exclusively. There is no Provider/Riverpod/
GetX/setState-for-shared-state. Local, ephemeral UI state (text controllers,
"is this sheet open") stays in `StatefulWidget` state; everything shared or
persisted goes through a BLoC.

## 1. Global provisioning

All BLoCs are created **once**, at app start, in
`core/bloc_providers/app_bloc_providers.dart` (`MultiBlocProvider`). Screens
**never** create their own `BlocProvider`. They access BLoCs with:

```dart
context.read<XBloc>()     // dispatch events / one-off reads
context.watch<XBloc>()    // rebuild on every state change
BlocBuilder<XBloc, XState>(buildWhen: …, builder: …)   // scoped rebuilds
BlocListener<XBloc, XState>(listenWhen: …, listener: …) // side effects (snackbars, nav)
```

### Registered BLoCs

| BLoC                 | Constructed with                       | Eager init event |
|----------------------|----------------------------------------|------------------|
| `ThemeBloc`          | —                                      | `LoadTheme` |
| `AuthBloc`           | `AuthRepository`                       | `CheckAuthStatus` |
| `ContactBloc`        | `ContactRepository`                    | — |
| `MessageBloc`        | `MessageRepository`, `SmsService`, `ContactRepository` (optional, default real) | — (starts on first `LoadThreads`) |
| `DraftBloc`          | `DraftRepository`                      | — |
| `CallLogBloc`        | `CallLogService`, `CallLogRepository` (optional, default real) | — |
| `DialerBloc`         | `ContactRepository`                    | `DialerLoadContacts` (in ctor) |
| `FavoritesBloc`      | `FavoritesRepository`                  | `LoadFavorites` |
| `SearchBloc`         | `ContactRepository`, `CallLogRepository` | — |
| `SettingsBloc`       | —                                      | `LoadSettings` |
| `BlockedNumbersBloc` | `BlockedNumbersRepository`             | `LoadBlocked` |

> Note: every stateful BLoC now takes its repositories/services through the
> constructor (optional, defaulting to the real implementations), so
> `AppBlocProviders` constructs them with no args while tests inject mocks. This
> is the preferred style — see `STATE_MANAGEMENT.md` §6.

## 2. Event / State conventions

- Events and states extend **`Equatable`** so BLoC can de-dupe identical states.
- States are usually **sealed-style class hierarchies**: an `Initial`, a
  `Loading`, one or more loaded states, and an `Error`.
- Events are imperative verbs: `LoadThreads`, `SendMessage`, `ArchiveThreads`.

Example (`MessageState`): `MessageInitial → MessageLoading → ThreadsLoaded |
MessagesLoaded | MessageSent | MessageSendFailed | MessageError`.

## 3. State guards that protect the UX

These are **load-bearing** behaviours — do not "simplify" them away:

- **No flash-to-loading on background refresh** (`MessageBloc._onLoadThreads`):
  `MessageLoading` is only emitted when the current state is **not** already
  `ThreadsLoaded`/`MessagesLoaded`. An incoming SMS triggers a silent thread
  refresh without blanking the chat screen.
- **Conversation stays put on cross-thread messages** (`_onReceiveMessage`): a
  message for a *different* thread does not replace `MessagesLoaded` with
  `ThreadsLoaded`.
- **Scoped rebuilds**: `MainNavigation`'s unread badge uses `buildWhen` to
  rebuild only when the unread total changes; the dialer keypad reads
  `SettingsBloc` once (no rebuild on tone toggle).
- **Optimistic call teardown** (`DialerBloc._onEndCall`): the call UI resets
  immediately and the native `endCall()` is fire-and-forget, so the in-call
  screen dismisses without waiting for the platform round-trip.

## 4. Session-scoped caches (held inside BLoCs/services)

| Cache | Owner | Why |
|-------|-------|-----|
| `_hasImported` | `MessageBloc` (static) | Import device SMS once per session |
| `_cachedPhoneToName` | `MessageBloc` | Resolve contact names without re-fetching device contacts every `LoadThreads` |
| `_cache` (call logs) | `CallLogService` (static) | Avoid re-reading the device call log on every tab visit |
| `_listening` | `SmsService` | Register the SMS `EventChannel` at most once |
| `sms_imported_v1` | `SharedPreferences` | Persist the "already imported" flag across restarts |

## 5. Side effects

- **Navigation and snackbars** belong in `BlocListener`, never in `builder`.
- **`MainNavigation`** hosts a `BlocListener<DialerBloc>` that would push the
  incoming/in-call screens — currently dormant under "Option A" cellular calling
  (see `ARCHITECTURE.md` §5.2).

## 6. Testing the BLoC layer

`bloc_test` + `mocktail` are dev-dependencies. All stateful BLoCs now take their
repositories/services through the constructor (defaulting to real
implementations), so they can be unit-tested with mocks — e.g.
`DialerBloc(mockRepo, callService: mockCallService)` or
`MessageBloc(repository: …, smsService: …, contactRepository: …)`. `SettingsBloc`
is tested with `SharedPreferences.setMockInitialValues`. Repository tests run the
real schema on an in-memory `sqflite_common_ffi` database (see
`CONTRIBUTING.md`). Current suite: **138 tests**.
