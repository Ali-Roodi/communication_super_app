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

| BLoC | Eager | Init event |
|---|---|---|
| `ThemeBloc` | — | `LoadTheme` |
| `EditionBloc` | yes | `LoadEdition` — the edition and its activation |
| `AuthBloc` | — | `CheckAuthStatus` |
| `SecureSessionBloc` | yes | `SecureSessionRefresh` — the secure section's lock state |
| `KeyBankBloc` | — | — |
| `SecureMessagesBloc` | — | — |
| `SimBloc` | — | `LoadSims` |
| `ContactBloc` | — | — |
| `MessageBloc` | — | — (starts on the first `LoadThreads`) |
| `DraftBloc` | — | — |
| `TemplateBloc` | — | — |
| `ScheduledMessageBloc` | yes | `LoadScheduled` — re-arms the delivery alarm |
| `CallLogBloc` | — | — |
| `HiddenBloc` | yes | — (follows the secure section) |
| `DialerBloc` | — | contacts in its constructor |
| `FavoritesBloc` | — | `LoadFavorites` |
| `SearchBloc` | — | — |
| `SettingsBloc` | — | `LoadSettings` |
| `BlockedNumbersBloc` | — | `LoadBlocked` |

"Eager" is `lazy: false`: created at startup, not on first read. The comments in
`app_bloc_providers.dart` say why each one has to be; the order there matters
(`test/widget/app_bloc_providers_test.dart` builds them in it).

Every BLoC takes its repositories and services through the constructor
(optional, defaulting to the real ones), so `AppBlocProviders` builds them with
no arguments and tests inject mocks.

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
  screen dismisses without waiting for the platform round-trip. That early
  reset is also what excludes a hand-hung-up call from «تماس مجدد خودکار»: the
  `DISCONNECTED` that follows finds the status already idle.
- **A redial series is state beside the call, not a call status**
  (`DialerState.autoRedial`): while it counts down there is no call, and every
  teardown path (`_idleState`, `CALLS_CHANGED count=0`, `SyncCallState`) may run
  — `copyWith` never touches the field unless `clearAutoRedial` is named. One
  native teardown can deliver up to three `DISCONNECTED`s, the first sometimes
  without a cause; only a verdict on a dialling call (`_RedialVerdict.decided`)
  may end the series.

## 4. Session-scoped caches (held inside BLoCs/services)

| Cache | Owner | Why |
|-------|-------|-----|
| `_hasImported` | `MessageBloc` (static) | Run the full device mirror-sync once per session; resumes run a throttled one |
| `_cachedPhoneToName` | `MessageBloc` | Resolve contact names without re-fetching device contacts every `LoadThreads` |
| `_cache` (call logs) | `CallLogService` (static) | Avoid re-reading the device call log on every tab visit |
| `_listening` | `SmsService` | Register the SMS `EventChannel` at most once |
| `contact_name_cache` | SQLite table | Name the first paint of the inbox and «اخیر» before the address book answers (see `DEVELOPER_GUIDE.md`) |

## 5. Side effects

- **Navigation and snackbars** belong in `BlocListener`, never in `builder`.
- **`CallUiCoordinator`** (above the auth flow, see `ARCHITECTURE.md` §5.2)
  hosts the `BlocListener<DialerBloc>` that pushes the incoming/in-call screens
  and keeps the ended-call screen up while a redial counts down.

## 6. Testing the BLoC layer

`bloc_test` + `mocktail` are dev-dependencies. All stateful BLoCs now take their
repositories/services through the constructor (defaulting to real
implementations), so they can be unit-tested with mocks — e.g.
`DialerBloc(mockRepo, callService: mockCallService)` or
`MessageBloc(repository: …, smsService: …, contactRepository: …)`. `SettingsBloc`
is tested with `SharedPreferences.setMockInitialValues`. Repository tests run the
real schema on an in-memory `sqflite_common_ffi` database (see
`CONTRIBUTING.md`). The native side has its own JVM tests under
`android/app/src/test/` (crypto vectors, wire format, key bank, cover text).
