# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get          # Install dependencies
flutter run              # Run on connected device/emulator
flutter run --release    # Run in release mode
flutter build apk        # Build Android APK (debug)
flutter build apk --release  # Build release APK (local only — see below)
scripts/release_build.sh     # Build the APK a STORE gets: versionCode from git, signature verified
flutter analyze          # Run linter (flutter_lints)
flutter test             # Run all tests
flutter test test/widget_test.dart  # Run a single test file
```

## Where the detail lives

This file holds what applies wherever you are working. The per-area notes below are
**not optional reading** — they carry load-bearing invariants, and most of them exist
because something was broken in a way that was not obvious from the code. **Read the
matching file before changing anything in that area**, and update it in the same commit
as the code.

| File | Read it before touching |
|---|---|
| `docs/architecture/dialer-and-calls.md` | the keypad, «اخیر», the ROLE_DIALER / `CallInCallService` path, `CallUiCoordinator`, the incoming/in-call screens, lock-screen and recents behaviour, USSD/MMI dialling, speed dial, voicemail, «تماس مجدد خودکار», the role-request gate |
| `docs/architecture/sms-role-and-sync.md` | the SMS send/receive pipeline, ROLE_SMS, `content://sms` write-through, the mirror-sync and its soft deletes, call-log sync, and every incoming-SMS notification (all posted natively) |
| `docs/architecture/contacts.md` | contact extras, merging/linking, labels («برچسب‌ها») and their account rules, the contact photo path, «قالب نام» / ordering, and the cache-revision signal that makes a rename reach every screen |
| `docs/architecture/inbox-search-and-groups.md` | `MessageRepository.searchMessages` / `searchThreads`, blocking & spam, «گفتگوی جدید», group conversations (`g:` thread ids), and the `MessageBloc` state guards |
| `docs/architecture/conversation-and-composer.md` | the bubble, the composer, «اندازه متن پیام», the emoji panel, links/USSD inside a message, one-time codes, delivery ticks, and what a refused send leaves behind |
| `docs/architecture/scheduled-messages.md` | anything scheduled — the sheet, the two deliverers, claiming, jitter, the alarm |
| `docs/architecture/dual-sim.md` | anything that names a SIM: `subscriptionId`, per-thread SIM memory, the pickers, SIM contacts |
| `docs/architecture/drafts-and-templates.md` | drafts, categories, «قالب آماده» and the template SMS wire format |
| `docs/architecture/settings.md` | the settings pages |
| `docs/publishing/store-release.md` | anything about shipping the app to بازار / مایکت — the signing key, the store permission review, the store listing, the release pipeline. It carries the **live status** of the launch: update its status table and history in the same commit as the change. |

Two rules from those files apply **everywhere** and are repeated here so they cannot be
missed:

- **No plugin in this app may request a runtime permission.** Every grant goes through
  `PermissionGate`. A plugin that opens its own dialog both double-asks and — since these
  plugins keep exactly one `MethodChannel.Result` — dies the moment two calls overlap
  (`IllegalStateException: Reply already submitted`, an uncatchable crash on the main
  looper). This is why `call_log`, `another_telephony`, `image_picker` and `image_cropper`
  are not used; see `sms-role-and-sync.md` and `contacts.md`.
- **Any batch handed to the contacts provider is chunked below 500 operations.** A batch
  that crosses `ContactsProvider2`'s ceiling writes nothing at all, and through
  `flutter_contacts` it takes the process with it. See `contacts.md`.

**Kotlin/Dart mirrors that must change together:** `ScheduledSmsWorker.kt` ↔
`scheduled_message_model.dart`, `TemplateWire.kt` ↔ `message_template_model.dart`,
`BlockedNumbers.kt` ↔ `PhoneNormalizer`. A mismatch does not fail loudly — it silently
does something different.

## Architecture

This is a Flutter Android SMS/phone app with a Persian (RTL) UI. The internal app name is **هم‌رسان**.

**The launcher icon is generated, not hand-drawn.** `Hamresan-Logo.svg` (512×512, navy `#023066` ground) is rasterised to the legacy square mipmaps and, separately, to a transparent-artwork adaptive foreground sized to 68 dp inside the 108 dp canvas — safely inside the 66 dp safe zone, so no launcher mask can bite the outer ring — with `@color/ic_launcher_background` carrying the logo's own ground. Re-generate both halves together from the SVG; a square full-bleed picture used as an adaptive *foreground* gets its corners cropped by every round mask.

### Entry flow

`main.dart` → `AppBlocProviders` (MultiBlocProvider) → `AppLockWrapper` → `AuthWrapperScreen` → `PermissionGate` → `MainNavigation`

- **`AppBlocProviders`** (`lib/core/bloc_providers/`) provisions all BLoCs globally at startup.
- **`AuthWrapperScreen`** routes based on `AuthBloc` state: `AuthNotSet` → PIN setup, `AuthSet` → PIN entry, `AuthAuthenticated` → `PermissionGate`.
- **`PermissionGate`** (`lib/core/widgets/`) batches all runtime permission requests (SMS, Phone, Contacts) via `PermissionService` *before* `MainNavigation` is built — this prevents a crash caused by multiple `IndexedStack` screens simultaneously requesting permissions.
- **Nothing on the way in draws a spinner.** The two gates before the app — the permission check and the auth-state read — render a blank `Scaffold`, and `hasAllRequiredPermissions` runs its four reads with `Future.wait` instead of one after another. Each resolves in a few frames, so a spinner there does not inform anybody; it just makes every single launch look like it is loading, which is exactly how it was reported. Measured cold start on the test device: ~1.8 s from `am start` to a painted, populated «اخیر», no dropped frames.
- **Nothing before the app draws a spinner, and «اخیر» paints from SQLite.** `DefaultAppGate` used to hold a full-screen `CircularProgressIndicator` over four *sequential* platform reads on every launch, and `CallLogBloc._onLoadCallLogs` used to `await` the device mirror-sync **and** the whole address book before its first emit. Between them that was the reported «هر بار ۲ ثانیه لودینگ». Now: the gate renders blank and runs its four reads with `Future.wait`; the call log emits the local page immediately — **named from `ContactNameCache`**, not as bare numbers (that first-paint-then-names flicker was itself reported: «شماره‌ها نشان داده می‌شوند و با یک فاصله کوتاه اسم‌ها می‌آیند») — overlays the authoritative names as a *second* emit, and runs the device pass detached (`_backgroundSync`, once per bloc — `ensureSynced` reports "I went to the device", which on a phone with an empty call log is true every time, so an unlatched re-dispatch would loop). A spinner is emitted only when there is genuinely nothing to show, and «تماس اخیری وجود ندارد» is withheld until the device has actually been read once. Measured on the test device: a populated, named «اخیر» one second after `am start`.
- **An empty inbox during the first import says so** (`ThreadsLoaded.syncing` → `MessagesImportingState`). A fresh install has nothing local while the mirror-sync walks the whole provider, and «هیچ پیامکی موجود نیست» over a phone full of messages reads as data loss. The rows replace it page by page as the import lands.
- **`MainNavigation`** is a bottom-nav shell with 4 tabs: Dialer (0), Call History (1), Contacts (2), Messages (3).
- **`MainNavigation` picks its landing tab** when the app is opened: «پیام‌ها» if an SMS arrived while the app was away, «اخیر» if a call was missed, the newer of the two when both happened. The comparison point is a persisted `last_foreground_at` (stamped on every non-resumed lifecycle event), so "new" means *since the user last looked* — not "unread", which would re-hijack the tab on every launch until the inbox was emptied. It costs **no new queries**: every tab is mounted from the start, so it listens to `MessageBloc` / `CallLogBloc` state the app already produces, waits a short grace window for both to answer (picking the newer needs both, and one of them may have nothing to report), then unsubscribes. A notification deep link marks the decision resolved so the grace timer cannot swing the tab under an already-open conversation. A first-ever launch has no stored moment and lands on the default.

### Feature structure

Each feature under `lib/features/<name>/` follows the pattern:
```
bloc/       # BLoC events, states, bloc class
models/     # Data models
repositories/ # SQLite access via DatabaseHelper
screens/    # Flutter UI widgets
services/   # (messages, call_history only) Native/plugin bridging
```

Features: `authentication`, `messages`, `contacts`, `dialer`, `call_history`.

### State management

All state is BLoC (`flutter_bloc`). BLoCs are provided globally in `AppBlocProviders` — do not create new `BlocProvider`s inside screens; use `context.read<XBloc>()` / `context.watch<XBloc>()`.

### Database

Single SQLite database (`communication_app.db`, version 24) managed by `DatabaseHelper` singleton (`lib/core/database/`). Tables: `contacts`, `messages`, `call_logs`, `favorites`, `blocked_numbers`, `archived_threads`, `pinned_threads`, `message_categories`, `drafts`, `message_templates`, `scheduled_messages`, `thread_sim`, `speed_dial`, `message_groups`, `message_group_members`, `message_group_targets`, `contact_name_cache`, `unread_marks`. Constants in `AppConstants`.

**Schema invariants:**
- `contact_name_cache` (DB v23, `ContactNameCache`) is the address book as `ContactRepository.getDeviceContacts` last read it — normalized number → name + contact id — and it is a **cache, never a source of truth**. It exists because the address book is on the far side of a platform channel: both the inbox and «اخیر» paint from SQLite immediately and used to do it as bare *numbers*, dropping the names in as a second emit a beat later, on every single launch. Now the first emit is named from this table and the authoritative read still runs behind it; when nothing has changed the second emit is `==` to the first and `ThreadsLoaded` / `CallLogsLoaded` being Equatable means nothing repaints. Two rules keep it honest: only a completed device read writes it (so it cannot drift), and the write **replaces the whole set** in one transaction rather than upserting — an upsert-only cache would go on naming a contact the user deleted.
- `messages.thread_id` is the digits-only normalized phone number — **except** for a group conversation, where it is `'g:' || message_groups.id` (`GroupThread`). That is why every inbox/search/pin/archive query works on a group without a branch, and why nothing may pass a thread id to a *display* helper without checking `isGroup` first.
- `messages` has a unique index on `(phone_number, body, timestamp, type)` (DB v3) — all batch inserts must use `ConflictAlgorithm.ignore` to silently skip duplicates.
- `messages.is_read` marks unread messages; every *sent* row is inserted with `is_read = 1` (composer, scheduled worker, device import alike). The inbox's `unread_count` therefore counts unread rows of **any** type — it must not filter on `type = 'received'`, or a thread the user only ever sent to (or whose received rows are all soft-deleted) can never be shown as unread. `markThreadAsRead` clears the flag on every type for the same reason — filtering it would strand such a thread bold for ever.
- `unread_marks` (DB v24) is «علامت‌گذاری نخوانده», and it holds **no message**. A hand-mark and a message that actually arrived are different facts and the inbox draws them differently — a bare dot versus the real count — so the mark cannot be expressed by setting `is_read = 0` on a row: any row it flags is then indistinguishable from a real arrival, which is how the badge ended up reading «۴۷» (every received row flagged) and then a fake «۱» (only the newest). `MessageThread.manuallyUnread` carries it and `markThreadAsRead` deletes it. See `inbox-search-and-groups.md`.
- `drafts.is_pinned` / `message_categories.is_pinned` (DB v14) float a row to the top of its list. `DraftRepository.upsertDraft` REPLACEs the row, so `DraftBloc._onSave` re-reads the existing draft and carries the flag over — without that, editing a draft silently unpinned it.
- `blocked_numbers.normalized` is the **canonical thread id** (`09xxxxxxxxx`) — the same key `messages.thread_id`, `PhoneNormalizer.toThreadId` and the native `BlockedNumbers.normalizeToThreadId` produce. It used to be a raw digits-only strip of whatever string the caller happened to hold, which is why **blocking did nothing at all**: a number blocked from a conversation was stored as `989121234567` (the address as the carrier delivered it) while every lookup — Dart and Kotlin alike — asked for `09121234567`. The row was there and the check never found it. Only `BlockedNumberModel.normalize` may produce this column; DB v16 rewrites the rows written before it (in Dart — `toThreadId` is not expressible in the SQL a migration can run — deduplicating on collision, oldest row wins, because the column is UNIQUE).
- `favorites.normalized` is the **same canonical key** (`PhoneNormalizer.toNational`), for the same reason and after the same bug: it is a UNIQUE column, and while it held a raw digits-only strip one person could be starred twice — once from a call log carrying `+989121234567`, once from Contacts carrying `09121234567` — with `isFavorite` answering false on whichever surface asked with the other form. DB v19 rewrites the old rows (dedupe, oldest wins). `FavoriteModel.normalize` returns **empty** for a string with no digits, and `FavoritesRepository` normalizes inside `isFavorite`/`removeFavorite` so a caller holding a display number cannot miss the row.
- The same canonicalization applies to the two grouping keys in «اخیر»: `CallHistoryScreen._normalize` (which decides whether consecutive calls collapse into one «(۲)» row) and `call_detail_sheet._normalize` (which filters «تماس‌ها با این مخاطب»). Both were digits-only strips and both split one contact in two whenever the carrier changed format between calls.
- `blocked_numbers.is_spam` / `reported_at` (DB v16) mark «مسدود کردن و گزارش هرزنامه» as opposed to a plain block. One table, not two lists: Google keeps both in the same page and only one of them is a report.
- A migration that ALTERs a table an earlier step of the *same* upgrade may have just created at its newest shape must guard on `_columnsOf` — an unconditional `ADD COLUMN` there aborts the whole upgrade. This is real for `blocked_numbers`: `oldVersion < 5` creates it, `oldVersion < 16` alters it.
- `messages.device_sms_id` (DB v11) is the row id of the message inside the device SMS provider (`content://sms`). It is the key of the mirror-sync diff and of global deletes. Null means "no known provider row" (e.g. sent while the app wasn't the default SMS app) — such rows are never deleted by the sync.

Migrations live in `DatabaseHelper._onUpgrade`. When bumping `AppConstants.databaseVersion`, add a migration block there.

### Contact search

Every contact filter — the contacts tab, the dialer suggestions, `searchContacts` — goes through `SearchText` (`core/utils/search_text.dart`) and `ContactRepository.matchContacts` / `matchPhoneDigits`. A raw `String.contains` is not a search on this address book and missed contacts that were plainly there:

- **Numbers are matched in every equivalent form.** `+98…` ≡ `0098…` ≡ `98…` ≡ `09…` ≡ `9…` — both the stored number and the typed query are expanded (`SearchText.phoneForms` / `queryForms`), so a contact saved as `+98 912 123 4567` is found by any of them. Asymmetry that must stay: the digits **as typed** match anywhere in the number, but a form derived by stripping a trunk `0` or the `98` country code only matches at the **start** — otherwise searching `021…` returned every mobile containing `21`.
- **Names are folded**: ي→ی, ك→ک, آ/أ/إ→ا, ة→ه, ؤ→و, harakat/ZWNJ/bidi marks dropped, Persian+Arabic digits → ASCII, and spacing optional («محمدرضا» finds «محمد رضا»). Highlighting uses `SearchText.matchRange`, which returns indices into the *original* string — folding drops characters, so an index taken on the folded copy lands on the wrong letter.
- **Performance:** a query is compiled **once per list** into a `PhoneQuery`, never per contact, and `phoneForms` is memoized per number string. Both matter: this runs over the whole address book per keystroke. The contacts screen also resolves the matched number per *query* (`_resultNumbers`), not in each row's `build`.
- `DialerBloc._onFilterContacts` **re-reads `getAllContacts()` on every filter** (a cached-list hand-back in the normal case). Filtering the snapshot taken in the constructor is why a number just saved never became a suggestion until restart.
- `SearchBloc` (the unified «اخیر»/inbox search) goes through the same matcher. It used to carry its own raw lowercase/digit-substring test and answered the identical query differently.

**The keypad is also a T9 name search.** The same digits are read twice: as a number (`PhoneQuery`) and as the letters printed on the keys (`SearchText.t9Of` / `t9MatchRange`), both inside `matchPhoneDigits`. A `PhoneMatch` carrying `nameStart >= 0` is a T9 hit and the dialer row highlights the *name* instead of the number.

- The letter table is **Persian** (`SearchText._t9Groups`, ۲ `ابپتث` … ۹ `هی`) plus the latin groups, and `DialerScreen._keyRows` prints the same table on the keys — a keypad that finds «کبری» under ۷۲۴ has to say so, or the feature is invisible. Latin names are still matched; the keys just have no room for two alphabets.
- **Matches start at a word only** (`T9Name.wordStarts`) and need ≥ `SearchText.minT9Length` digits. Matching mid-word answers three digits with the whole address book, and one digit is a third of it — the number suggestions are the useful answer at that length.
- Number hits are listed first and a contact already listed for its number is never repeated as a T9 hit.
- `T9Name.positions` maps each digit back to the **original** name, for the same reason `SearchText.matchRange` does: folding drops characters, so an index into the folded copy highlights the wrong letter.

**Every contact row shows its numbers under the name** (`ContactNumbersLine`, `core/widgets/`) — contacts tab, unified search, favourites picker. A name-only row cannot tell two «علی» apart. The line shows the number a digit query *matched* (emphasised via `HighlightedPhone`) when there is one, otherwise the contact's numbers separated by «·» with a «+N» tail. The contacts tab's `_kRowHeight` is sized for those two lines — it feeds the fast-scroll index's jump offsets, so changing the row's height means changing that constant.

### Transient confirmations

`showUndoSnack` (`core/widgets/undo_snack_bar.dart`) is the app's only snack bar carrying an action. **A `SnackBar` with an action is not guaranteed to time out**: `ScaffoldMessengerState` skips starting its dismissal timer while `MediaQuery.accessibleNavigation` is true, so with any accessibility service active «گفتگو بایگانی شد» sat on the inbox until something else replaced it. This helper owns its own `Timer` and hides the bar itself, so the 3-second window is authoritative whatever the platform reports — and it *shows* the countdown as a shrinking ring around «واگرد», because an undo the user cannot see expiring is a guessing game. `showCountdown: false` for an action that is a shortcut rather than an undo («تنظیمات»), where a ticking clock would imply a deadline that is not one.

### Long-press & selection

Long-press is the *same gesture everywhere*, matching Google Messages / Phone / Contacts:

- **Chat bubble → lift, select text.** `MessageBubble` (stateful, holds a `GlobalKey` on its box) measures the bubble's global rect *and* where inside it the finger landed, then hands both to `showMessageActionOverlay` (`widgets/message_action_overlay.dart`). The overlay is a `PopupRoute` that blurs the backdrop, animates the bubble from its list position to a lifted one, and makes the body selectable — the Telegram flow. The action card (ستاره / کپی / هدایت / اطلاعات / انتخاب / حذف) hangs off the bubble's own edge.
  - **The lifted bubble is NOT scaled, and that is a selection fix.** It used to be drawn 6 % larger through a `Transform.scale` around the whole copy. `SelectableRegion` positions the **magnifier** from `getTransformTo(null).getTranslation()` — the translation only — so under any scale the glass focuses `(scale − 1) × offset-inside-the-bubble` away from the handle, which on a long message is a different line; the same mismatch runs through the handle drag, which subtracts a *local* half-line-height from a *global* drag position. The lift is carried by the movement, the shadow and the blur instead. Do not put a scale back.
  - There is deliberately **no «انتخاب متن» menu row and no select-text dialog** any more; selection happens on the lifted bubble itself.
  - Nothing is selected when the overlay opens — the lift is **only** a zoom. A long-press *inside* the lifted bubble then selects the word under the finger and the handles widen it.
  - The lifted body is `SelectableBubbleText`, which wraps the **same `LinkifiedText` widget** the flat bubble renders in a `SelectionArea`. Do not swap that for a `TextField`/`SelectableText` copy: those lay out through `RenderEditable`, which reserves a caret margin, so the text re-wrapped one line longer than the original and the lifted bubble collided with the action menu. Same widget in, same wrapping out — which is also what lets the overlay position the menu from `anchor.height`.
  - **«جستجو در وب» is ours, added to the toolbar.** The framework's own item list has no search on Android, so `SelectableBubbleText` is stateful, tracks the live selection through `SelectionArea.onSelectionChanged` (`SelectableRegionState` keeps its selected content private) and appends a button that opens `google.com/search?q=…` through `url_launcher`. A search *URL* rather than `ACTION_WEB_SEARCH`: the intent needs native plumbing and resolves to nothing on a phone whose browser never registered for it. The selection is held in a plain field, not `setState` — nothing on screen depends on it and rebuilding the lifted bubble would fight the drag handles.
  - The selection toolbar **relabels `SelectableRegionState.contextMenuButtonItems`** («کپی» / «انتخاب همه») rather than re-implementing copy; the app ships no Persian `MaterialLocalizations`, so the stock labels would be English. `copySelection` is deprecated — go through the button items.
  - The bubble box is rendered by `MessageBubbleBody`, shared by the list and the overlay — the zoomed copy must be the *same* widget or the lift visibly jumps. `LinkifiedText.buildSpan` is likewise shared so links look identical in the selectable copy (inert there).
  - The scrim is inside the page (it has to be blurred) and is wrapped in `IgnorePointer` so the dismissing tap reaches the route's own modal barrier underneath.
  - The app ships no Persian `MaterialLocalizations`, so the selection toolbar's labels («کپی», «انتخاب همه») are supplied by hand in `MessageBubbleBody._selectionToolbar`.
- **Thread row → multi-select**, not a sheet (`showThreadOptionsSheet` was deleted). Every action it used to hold lives in `MessagesSelectionAppBar`. Draft-only rows are synthetic (no conversation behind them), so their long-press still just discards the draft.
- **Contact row → multi-select** with a contextual bar (count · ستاره · اشتراک‌گذاری · حذف · انتخاب همه). Deletes go to the DEVICE address book via `FlutterContacts.deleteContacts`, then invalidate `ContactRepository` + `LazyContactAvatar` caches and dispatch `RefreshContacts`. Share is single-selection only — the platform sheet takes one contact.
- **Draft card → multi-select**, **category row → multi-select** (سنجاق · انتقال/تغییر نام · حذف · انتخاب همه). Both use the shared `SelectionAppBar` + `SelectionCheck` from `core/widgets/selection_app_bar.dart` — the inbox keeps its own **sliver** bar (`MessagesSelectionAppBar`) only because its header collapses. The virtual «همه» / «بدون دسته‌بندی» rows are never selectable: there is no table row behind them to rename, delete or pin. Multi-select is off in the drafts **picker** (`pickMode`).
- Every long-press fires `HapticFeedback.mediumImpact()`.

**Tapping a phone number inside a message** opens `showPhoneActionSheet` (تماس / ارسال پیامک / مشاهده مخاطب or افزودن به مخاطبین / کپی شماره). It must NEVER launch a `tel:` intent: this app is the default dialer, so the intent resolves back into its own process — the UI froze for ~9 s, swallowed the gesture and could take the activity down. The contact lookup runs *after* the sheet is on screen (cold address book) and is wrapped in a try/catch so a missing permission still leaves call/SMS/save usable.

### Authentication & app lock

- Auth type (PIN or pattern) is stored in `flutter_secure_storage`; the credential itself is stored **salted and stretched** (`v2:<salt>:<hash>`, 60 k rounds of SHA-256), not in plaintext. Rows written by older versions are plaintext and are upgraded in place on the first *successful* validation — never on a wrong guess.
- **A forgotten PIN is no longer a permanent lockout.** Setting a PIN mints a one-time recovery code (`AuthRepository.regenerateRecoveryCode`, hash-only storage, unambiguous alphabet with no O/0 or I/1) which `PinSetupScreen` shows once via `RecoveryCodeScreen`. `AuthBloc` emits `AuthRecoveryCodeIssued` **before** `AuthAuthenticated` for that reason — reorder them and the code is minted and lost in the same frame. «رمز را فراموش کرده‌ام» on both lock screens verifies it and drops to the set-a-PIN flow; it never unlocks the app directly, because a code written on paper must not become a second password. Settings → «کد بازیابی جدید» re-mints it from inside an unlocked app.
- **"Unlocked" is process memory, never storage** (`AuthRepository.isAuthenticated` / `setAuthenticated`). It used to be persisted in secure storage and nothing ever reset it, so after the first PIN entry the lock never appeared again — not from the background, not after a restart. A new process is always locked; `setAuthenticated` also deletes the flag older builds left behind.
- **`AppLockWrapper` re-locks an open session** after the app sat in the background longer than «قفل خودکار» (Settings → امنیت; فوراً / ۱ / ۵ / ۳۰ دقیقه, default 1 min, `AuthRepository.relockAfterSeconds`). The lock is a **route** on `appNavigatorKey` (`RelockScreen`, `PopScope(canPop: false)`), not an overlay above the navigator: it must cover every pushed screen and swallow back, and being a route is what lets `CallUiCoordinator` push a call screen over it. It never locks during a live call, only counts `paused`/`hidden` as leaving (not `inactive`), and checks the PIN through the repository so `AuthBloc` — and with it the whole app under the lock — is not rebuilt.
- **`AuthWrapperScreen` does not rebuild on transient states** (`AuthLoading`, `AuthValidationFailure`, `AuthRecoveryCodeIssued`). It did, both render as the blank fallback, and one wrong PIN at launch left a blank screen with no keypad and no way in. `ValidatePin`/`ValidatePattern` also return to `AuthSet` after a failure.

### Crash reporting

`CrashReporting` (`core/services/`) wraps `main`. Off unless a DSN was compiled in (`--dart-define=SENTRY_DSN=…`) **and** the user opted in (Settings → «تشخیص خطا», default off, takes effect next launch).

- It uses the **pure-Dart `sentry`**, not `sentry_flutter`: that package ships its own Android Gradle plugin pinned to AGP 7.4.2, which this project's build cannot resolve — `assembleDebug` fails outright. The cost is that Kotlin-side crashes are not reported; `FlutterError.onError` and `PlatformDispatcher.onError` are hooked by hand for the Dart half.
- **Nothing about a message leaves the device**: `sendDefaultPii` off, no screenshots or view hierarchy, `console`/`http`/`query` breadcrumbs dropped whole (`debugPrint` in this app legitimately prints bodies), breadcrumb `data` blanked, and every remaining string run through a redactor that replaces any run of ≥ 4 digits. Do not relax any of these — this is the default SMS app.

### RTL / Persian

All UI text is Persian. Wrap any new screen or dialog root with `Directionality(textDirection: TextDirection.rtl, ...)` or use `RtlAppBar`. The `PersianUtils` class and `AppConstants.persianNumbers` handle Persian digit conversion.
