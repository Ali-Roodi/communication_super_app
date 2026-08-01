# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get          # Install dependencies
flutter run              # Run on connected device/emulator
flutter run --release    # Run in release mode
flutter build apk        # Build Android APK (debug)
flutter build apk --release  # Build release APK
flutter analyze          # Run linter (flutter_lints)
flutter test             # Run all tests
flutter test test/widget_test.dart  # Run a single test file
```

## Architecture

This is a Flutter Android SMS/phone app with a Persian (RTL) UI. The internal app name is **هم‌رسان**.

### Entry flow

`main.dart` → `AppBlocProviders` (MultiBlocProvider) → `AppLockWrapper` → `AuthWrapperScreen` → `PermissionGate` → `MainNavigation`

- **`AppBlocProviders`** (`lib/core/bloc_providers/`) provisions all BLoCs globally at startup.
- **`AuthWrapperScreen`** routes based on `AuthBloc` state: `AuthNotSet` → PIN setup, `AuthSet` → PIN entry, `AuthAuthenticated` → `PermissionGate`.
- **`PermissionGate`** (`lib/core/widgets/`) batches all runtime permission requests (SMS, Phone, Contacts) via `PermissionService` *before* `MainNavigation` is built — this prevents a crash caused by multiple `IndexedStack` screens simultaneously requesting permissions.
- **`MainNavigation`** is a bottom-nav shell with 4 tabs: Dialer (0), Call History (1), Contacts (2), Messages (3).

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

Single SQLite database (`communication_app.db`, version 15) managed by `DatabaseHelper` singleton (`lib/core/database/`). Tables: `contacts`, `messages`, `call_logs`, `favorites`, `blocked_numbers`, `archived_threads`, `pinned_threads`, `message_categories`, `drafts`, `message_templates`, `scheduled_messages`. Constants in `AppConstants`.

**Schema invariants:**
- `messages.thread_id` is the digits-only normalized phone number.
- `messages` has a unique index on `(phone_number, body, timestamp, type)` (DB v3) — all batch inserts must use `ConflictAlgorithm.ignore` to silently skip duplicates.
- `messages.is_read` marks unread messages; every *sent* row is inserted with `is_read = 1` (composer, scheduled worker, device import alike). The inbox's `unread_count` therefore counts unread rows of **any** type — it must not filter on `type = 'received'`, or «علامت‌گذاری به‌عنوان نخوانده» silently does nothing on a thread the user only ever sent to (or whose received rows are all soft-deleted): `markThreadAsUnread` flags the received rows, and falls back to the newest non-deleted row of any type when there are none. `markThreadAsRead` clears the flag on every type for the same reason — filtering it would strand such a thread bold for ever.
- `drafts.is_pinned` / `message_categories.is_pinned` (DB v14) float a row to the top of its list. `DraftRepository.upsertDraft` REPLACEs the row, so `DraftBloc._onSave` re-reads the existing draft and carries the flag over — without that, editing a draft silently unpinned it.
- `messages.device_sms_id` (DB v11) is the row id of the message inside the device SMS provider (`content://sms`). It is the key of the mirror-sync diff and of global deletes. Null means "no known provider row" (e.g. sent while the app wasn't the default SMS app) — such rows are never deleted by the sync.

Migrations live in `DatabaseHelper._onUpgrade`. When bumping `AppConstants.databaseVersion`, add a migration block there.

### Drafts & categories

Two screens, one `DraftBloc`, both rebuilt on the Figma «پیش‌نویس‌ها» / «دسته‌بندی‌ها» boards in the Google Messages surface language (page plane → rounded sheet → tonal rows).

- **`DraftsListScreen`** is a two-column note board, not a list: a draft is a block of text of unknown length and a single column wastes half the screen on the short ones. `SliverTwoColumnBoard` (`core/widgets/two_column_board.dart`, shared with «قالب‌های آماده») deals cards alternately into two `SliverList`s inside a `SliverCrossAxisGroup`, so both columns stay lazily built while each card is exactly as tall as its text. **`SliverCrossAxisGroup` does NOT mirror for RTL** — it lays children out left-to-right regardless of `Directionality`, so the leading column is picked by hand; drop that and the board deals the newest draft to the left and reads backwards.
- The category filter is a **chip row** («همه» / «بدون دسته‌بندی» / one per category). It replaced a status chip that only *reported* the filter — changing it meant a round trip through the categories screen.
- **`MessageCategoriesScreen`** is pill rows carrying name + draft count, «همه» and «بدون دسته‌بندی» first as virtual rows backed by counts. Tapping filters the board and pops. `active` (the filter currently showing) and `selected` (multi-select) are different states and are drawn with different surfaces — they can be true at once.
- «تغییر نام» is hidden unless exactly one category is selected, and deleting categories moves their drafts to «بدون دسته‌بندی» (`deleteCategories`, one transaction). `DraftBloc` also clears a filter pointing at a category being deleted, otherwise the board sits on a filter nothing can match.
- Both screens prune ids that vanished underneath the selection (deleted, or filtered out) in a post-frame callback, so the contextual bar can never count rows that are gone.

### Message templates («قالب آماده»)

A template is a body of text with `[...]` **placeholders**; `TemplateEngine`
(`models/message_template_model.dart`) derives a form from them and substitutes
the answers back. This is the whole feature — there is deliberately no
per-template code, so a template the user writes gets exactly the same fill
screen as a built-in one. Rows live in `message_templates` (DB v15) and the
built-ins are seeded there by the schema (`DatabaseHelper._seedMessageTemplates`,
fixed ids, INSERT OR IGNORE): they are ordinary rows the user may edit, pin or
delete.

- **`TemplatesListScreen`** is the drafts board reused: `SliverTwoColumnBoard`
  (`core/widgets/`) deals cards into two lazily-built columns — extracted from
  `DraftsListScreen` when this screen needed the same layout, including the
  hand-picked leading column (`SliverCrossAxisGroup` does NOT mirror for RTL).
  `pickMode` (composer «+» sheet → `showTemplatePicker`) pops with the finished
  text; manage mode (inbox menu) edits and multi-selects (سنجاق · ویرایش ·
  حذف · انتخاب همه, edit only at exactly one selection).
- **A template with nothing to ask is a one-tap insert.** `needsInput` is false
  when there are no placeholders *and* the contact-name switch has no contact to
  name — those go straight into the composer without the fill screen.
- **`TemplateFillScreen`** renders the Figma «قالب آماده جلسه» page: «درج نام
  مخاطب» switch, generated inputs, live preview, انصراف / تأیید. «تأیید» only
  appears once something is filled (Figma shows the empty form with انصراف
  alone). Answers live in a plain map + a `ValueNotifier` revision: only the
  preview and the button listen, so typing does not rebuild the inputs.
- **A «تاریخ» and a «زمان» placeholder are merged into one «تاریخ و زمان»
  picker** (`TemplateEngine.fieldsOf`) and filled from a single moment — asking
  for them separately means two pickers for one date. Field kind is read from
  the placeholder's *name* (تاریخ/مورخ → date, ساعت/زمان/وقت → time,
  توضیح/متن/آدرس/نشانی/پیام → multi-line, else single-line).
- **Preview keeps unanswered placeholders, insertion drops them** (`preview:`
  flag on `render`). Dropping one also removes the preposition that introduced
  it (`_dropDanglingConnector`) — otherwise an unfilled «[مکان]» shipped an SMS
  reading «… در محل برقرار می‌باشد.». Only a standalone trailing word from the
  connector list is taken, so «مدیر [نام]» keeps «مدیر».
- «درج نام مخاطب» is a per-template *default* (`use_contact_name`) that the fill
  screen can still flip per use; on, it prefixes «<نام> عزیز» + newline.

### Scheduled messages

**UI: one sheet, no screen.** Long-pressing send (or «زمان‌بندی ارسال» in the «+» sheet) opens `showScheduleSendSheet` — quick times, a full date/time pick, then «تکرار» / «پراکندگی زمان ارسال» / «پایان تکرار». It only *returns* a `ScheduleChoice`; the composer then shows a banner and the send button becomes `schedule_send`, and the row is written when send is pressed — the Google Messages flow. There is deliberately **no** separate scheduling screen (the old `ScheduleMessageScreen` was deleted); rescheduling from the bubble sheet or the schedules list re-opens the same sheet seeded via `ScheduleChoice.fromMessage`.

The sheet has **two exits, and both are needed**: a quick time pops immediately (Google's one-tap flow, carrying whatever rules were set first), while «انتخاب تاریخ و ساعت» only *sets* the moment and keeps the sheet open so «تأیید» closes it. Without the second, editing was impossible — the only way to leave was to re-pick the time, so changing just the jitter of an armed schedule threw the moment away. The confirm button and the leading «زمان ارسال» row appear only once a moment exists (seeded from `initial`, or picked).

**«پراکندگی زمان ارسال» is top-level, NOT nested under «تکرار».** It used to render only when `repeat != none`, which hid it for the one case it matters most for — a single send that must not land on the round minute it was scheduled for. Jitter applies to one-shots (`isDueAt` gates on `effectiveSendAt` regardless of repeat), so the UI must offer it regardless too. The composer banner prints it via `scheduleDetailSummary` («هر روز · تا ۳۰ دقیقه پراکندگی»), and **tapping the banner re-opens the sheet** on the armed choice — only the ✕ clears it.

Two deliverers exist:
- **Dart** — `ScheduledMessageBloc` ticks every 30 s and calls `ScheduledDeliveryService.deliverDue()`.
- **Native** — `ScheduledSmsWorker.processDue()` runs from an AlarmManager broadcast when the app is dead.

When the alarm fires and the Flutter engine is alive, `ScheduledSmsAlarmReceiver` hands the delivery *back to Dart* over `ScheduledSmsChannel` (`deliverDue`) instead of sending natively. This is load-bearing: the native worker writes straight to SQLite, so a native send while the app is running leaves `ScheduledMessageBloc` and `MessageBloc` stale — the chat keeps its scheduled ghost bubble and never shows the sent message. `MainActivity` publishes the channel in `configureFlutterEngine` and clears it in `onDestroy`.

Still, they coordinate through `ScheduledMessageRepository.claimDue(now, token)`: one atomic `UPDATE … SET status='sending', claim_token=?` stamps the due rows, and each deliverer only processes rows carrying its own token. **Never send a scheduled message without claiming it first.** A row stuck in `sending` past `ScheduledMessage.staleClaimTimeout` is released back to `pending`.

**Jitter is enforced, not decorative.** `ScheduledMessage.jitterOffset` derives a *deterministic* offset inside the window from (id, scheduledAt, occurrenceCount) — a re-rolled offset would let a row fire early on the next tick — and `isDueAt` compares against `effectiveSendAt`. The window can't be expressed in SQL, so `ScheduledDeliveryService` reads `getDue`, filters, and passes the surviving ids to `claimDue(…, restrictTo:)`. `ScheduledSmsWorker.claimDue` (Kotlin) applies the same gate and hands rows whose window hasn't opened back to `pending`. «ارسال فوری» must bypass all of this: `SendScheduledNow` calls `deliverDue(force: {id})`.

Other invariants:
- A failed send backs off (`next_attempt_at`) and retries; only after `ScheduledMessage.maxAttempts` does it become `failed`.
- `advanceAfterSend()` **skips** occurrences missed while the device was off — it never replays them.
- `ScheduledSmsWorker` (Kotlin) mirrors the recurrence, retry and claim logic of `scheduled_message_model.dart`. Change both together.
- The native worker also inserts the delivered message into `messages`, so a background-delivered SMS shows up in its chat.
- Every outgoing message persisted anywhere is published on the static `SmsService.onMessageSent` stream; `MessageBloc` subscribes and folds it into the open conversation (this is what re-renders the chat after a scheduled send).
- `DeliverDueScheduled` re-reads the table on **every** tick, even when it sent nothing — the native worker may have completed a row directly in SQLite. Without this the ghost bubble survives until the app restarts.

### SMS pipeline

**Receiving:**
1. `SmsHandler.kt` (Android) registers a `BroadcastReceiver` for `SMS_RECEIVED`.
2. Events are pushed to Flutter via `EventChannel` (`com.example.communication_super_app/sms_events`).
3. `NativeSmsService` (Dart) wraps the `EventChannel` stream. Call `initialize()` exactly once — a second call is a no-op (guarded by `_initialized`).
4. `SmsService.listenToIncomingSms()` subscribes to `NativeSmsService.onSmsReceived`, persists the message, shows a notification, and calls `onMessageReceived` callback → `MessageBloc.add(ReceiveMessage(...))`.
5. The listener is registered at most once per session (`_listening` guard). `MessageBloc` starts it on the first `LoadThreads` event.

**Sending:**
`SmsService.sendSms` → `NativeSmsService.sendSms` → `MethodChannel` (`com.example.communication_super_app/sms`) → `SmsHandler.kt.sendSms`. The native side performs pre-flight SIM/service checks before calling `SmsManager`. Error codes: `NO_SIM_CARD`, `NO_SERVICE`, `PERMISSION_DENIED`, `SMS_SEND_FAILED`.

### Default SMS app role & device sync

The app requests the **default-SMS-app role** (ROLE_SMS) — banner in the inbox (`DefaultSmsBanner`), request flow in `SmsHandler.requestDefaultSmsRole` (RoleManager on Q+, `ACTION_CHANGE_DEFAULT` before; result resolved in `MainActivity.onActivityResult`, trusting `isDefaultSmsApp()` over resultCode). Manifest declares the four role-required components: `SmsDeliverReceiver` (SMS_DELIVER), `MmsReceiver` (WAP_PUSH_DELIVER stub — MMS is dropped), the `SENDTO`/`SEND` intent-filter on MainActivity, and `HeadlessSmsSendService` (RESPOND_VIA_MESSAGE).

**Responsibility split while default (do not double-handle):**
- `SmsDeliverReceiver` ONLY writes the incoming SMS into `content://sms` (the system stops doing this for the role holder).
- App-side persist/notify/UI keeps flowing through `SMS_RECEIVED` (`SmsHandler` dynamic receiver when alive, `IncomingSmsReceiver` on cold start) exactly as before.
- Every successful send (composer + native scheduled worker) **writes through** to `content://sms/sent` (`writeSentToProvider`) — otherwise the sent SMS is invisible to every other SMS app. The returned provider id lands in `messages.device_sms_id`.

**Mirror-sync (`SmsService.syncDeviceMessages`)** replaced the old one-shot import. Runs once per session on `LoadThreads` and silently on resume (`SyncDeviceMessages` event, no loading state). Steps: backfill `device_sms_id` (numeric-id rows), reconcile the 500 most-recent inbox+sent rows via `MessageRepository.reconcileDeviceRows` (known-id skip → exact content match → **fuzzy ±2 min match** — needed because live-received rows store the SMS-PDU timestamp while the provider stores receive time → insert), then hard-delete local rows whose `device_sms_id` vanished from the (uncapped) provider id set.

**The sync NEVER blocks a paint or the bloc's event queue.** `MessageBloc._startBackgroundSync` runs it as a detached future and only its completion comes back as `DeviceSyncFinished`; `_onLoadThreads` paints from the local mirror first. Awaiting it inside the handler cost ~5 s of spinner on a cold start *and* queued every other event (opening a conversation) behind it. Consequences to preserve: `_hasImported` is set in `_onDeviceSyncFinished` (only on success, so a permission-denied first run retries), `listenToIncomingSms()` starts *before* the sync (messages arriving during it used to have no listener), and the "no permission and nothing local" error is raised from `DeviceSyncFinished(ok: false)`, not from the load.

The stale-row diff (`removeRowsMissingFromDevice`) runs **inside SQLite** against a temp table of provider ids — pulling every local row over the platform channel to subtract in Dart is what jammed the UI thread mid-scroll on a full phone.

**Deletes are global:** `MessageBloc` delete events go through `SmsService.deleteMessagesGlobally` / `deleteThreadGlobally` (provider rows first — by `device_sms_id`, falling back to body+timestamp±10 s match; thread delete matches addresses by last-10-digits in `SmsHandler.deleteSmsThreadFromProvider`), then the local store. Never delete local-only; the mirror-sync would just be out of sync with the phone.

**The local half of a delete must be a SOFT delete** (`softDeleteMessages` / `softDeleteThread`). The tombstone keeps the row's `device_sms_id`, and `_knownDeviceSmsIds` (used by `reconcileDeviceRows`) deliberately ignores `is_deleted`, so a deleted message is recognised and skipped instead of re-imported. A hard delete looked fine until the next sync: the provider delete is a **no-op unless the app holds the SMS role**, so everything came back — usually noticed after an app restart. `deleteThread` (hard) is left only for local-only data and tests.

**Call-log sync:** `CallLogSyncHandler.kt` registers a ContentObserver on `CallLog.Calls` and pushes debounced change events (`call_log_events` EventChannel) → `CallLogBloc` runs a silent `SyncCallLogs` (no flicker, keeps pagination). `CallLogService.syncFromDevice()` mirrors: upsert device rows, delete numeric-id local rows missing from the device. In-app deletes use `deleteCallLogsGlobally` (provider delete via `WRITE_CALL_LOG`, then local). `NativeCallLogService.initialize()` is re-invoked on `LoadCallLogs` because the first observer registration can predate the READ_CALL_LOG grant.

**Contact extras / «برنامه‌های متصل»:** `ContactExtrasHandler.kt` reads the third-party Data rows on a contact (rows whose MIME type is outside the standard set). Two things this depends on, both easy to break: the manifest `<queries>` entries for `android.accounts.AccountAuthenticator` and `VIEW`+`vnd.android.cursor.item/*` (targetSdk 30+ package visibility otherwise hides the authenticator, `packageForAccountType` returns null and the whole section renders empty), and resolving the row's action to a **concrete component** before launching — messengers register several activity-aliases per custom MIME type, so an implicit intent (even with `setPackage`) pops an "Open with" sheet listing the same app twice.

**Contacts:** all writes go straight to the device address book via `flutter_contacts` (`AddEditContactScreen`); there are deliberately NO create/update/delete bloc events. `ContactRepository.getContactByPhoneNumber` resolves against the device-contact cache (normalized-number match) — the local `contacts` table is legacy and nothing writes to it.

The static contact cache carries a **generation counter**: `invalidateCache()` / `forceRefresh` bump it, and a read that started before the bump refuses to publish its (pre-write) snapshot. Saving a contact invalidates the cache while the `FlutterContacts.addListener` refresh already has a read in flight — without the guard that stale snapshot won, and a contact added from a call log stayed missing from the list *and* the search until the next app start.

### Contact search

Every contact filter — the contacts tab, the dialer suggestions, `searchContacts` — goes through `SearchText` (`core/utils/search_text.dart`) and `ContactRepository.matchContacts` / `matchPhoneDigits`. A raw `String.contains` is not a search on this address book and missed contacts that were plainly there:

- **Numbers are matched in every equivalent form.** `+98…` ≡ `0098…` ≡ `98…` ≡ `09…` ≡ `9…` — both the stored number and the typed query are expanded (`SearchText.phoneForms` / `queryForms`), so a contact saved as `+98 912 123 4567` is found by any of them. Asymmetry that must stay: the digits **as typed** match anywhere in the number, but a form derived by stripping a trunk `0` or the `98` country code only matches at the **start** — otherwise searching `021…` returned every mobile containing `21`.
- **Names are folded**: ي→ی, ك→ک, آ/أ/إ→ا, ة→ه, ؤ→و, harakat/ZWNJ/bidi marks dropped, Persian+Arabic digits → ASCII, and spacing optional («محمدرضا» finds «محمد رضا»). Highlighting uses `SearchText.matchRange`, which returns indices into the *original* string — folding drops characters, so an index taken on the folded copy lands on the wrong letter.
- **Performance:** a query is compiled **once per list** into a `PhoneQuery`, never per contact, and `phoneForms` is memoized per number string. Both matter: this runs over the whole address book per keystroke. The contacts screen also resolves the matched number per *query* (`_resultNumbers`), not in each row's `build`.
- `DialerBloc._onFilterContacts` **re-reads `getAllContacts()` on every filter** (a cached-list hand-back in the normal case). Filtering the snapshot taken in the constructor is why a number just saved never became a suggestion until restart.
- `SearchBloc` (the unified «اخیر»/inbox search) goes through the same matcher. It used to carry its own raw lowercase/digit-substring test and answered the identical query differently.

**Every contact row shows its numbers under the name** (`ContactNumbersLine`, `core/widgets/`) — contacts tab, unified search, favourites picker. A name-only row cannot tell two «علی» apart. The line shows the number a digit query *matched* (emphasised via `HighlightedPhone`) when there is one, otherwise the contact's numbers separated by «·» with a «+N» tail. The contacts tab's `_kRowHeight` is sized for those two lines — it feeds the fast-scroll index's jump offsets, so changing the row's height means changing that constant.

### Keypad touch

`DialKey` fires **on touch-down, through a raw `Listener`** — not on an `InkWell` tap. The keypad lives inside a draggable modal bottom sheet, so a tap recognizer has to win a gesture arena against the sheet's vertical drag: dialing fast means each press carries a few pixels of movement, the drag claims the pointer, and the tap is never delivered — digits went missing exactly when typing quickly. A `Listener` is not an arena member, so its callbacks always arrive (and two thumbs can type at once).

Consequences to preserve:
- Long-press is a **timer started on down**, cancelled by a release or by sliding past the slop — a `GestureDetector` long-press would be back in the arena.
- The digit is already typed when a long-press fires, so `_longPressFor` **deletes it first** (`0` → «۰» then «+»; `1` → delete then voicemail).
- `DialerScreen` has **no top-level `BlocBuilder`**. Every keypress emits a state, and rebuilding the 12 animating keys plus the suggestion list between one finger-down and the next is exactly the work that made presses land late. Only `DialerNumberDisplay`, the suggestions and the call pill sit in (narrow, `buildWhen`-gated) builders; `_KeyGrid` is built once, and the dialpad-tone setting is read per press instead of per build.

### Default dialer role & in-call UI

The app also requests the **default-dialer role** (ROLE_DIALER) — `CallHandler.requestDefaultDialerRole` (RoleManager Q+, `ACTION_CHANGE_DEFAULT_DIALER` before; resolved in `MainActivity.onActivityResult`). While the app holds the role, telecom binds `CallInCallService` and **this app is the ONLY call UI on the device**, incoming and outgoing:

- `CallInCallService.onCallAdded` registers a `Call.Callback` and mirrors telecom states into `CallEventStreamHandler` → `DialerBloc.callStatus` → `CallUiCoordinator` navigation. `stickyState` is replayed in `CallEventStreamHandler.onListen` so a cold-started engine never misses the ringing call.
- Incoming calls post a full-screen notification (`USE_FULL_SCREEN_INTENT`) with answer/decline actions (`CallActionReceiver`) — this is what launches the app when its process is dead.
- **`CallUiCoordinator` (main.dart, wraps `home`) sits ABOVE the auth flow deliberately**: an incoming call must surface over the PIN screen; only the call screens are exposed, the rest stays locked. Do not move call navigation back inside `MainNavigation`.
- **Lock screen:** `MainActivity.showOverLockScreen(true)` (`setShowWhenLocked` + `setTurnScreenOn` + keep-screen-on; pre-27 window flags) is what puts the call UI *over* the keyguard. Without it the full-screen intent lands behind the lock screen: black screen, no way to answer, phone still ringing. It is toggled per call — `CallInCallService.onCallAdded` turns it on, `onCallRemoved` turns it off, and `onCreate`/`onResume` re-derive it from `CallInCallService.hasLiveCall()` — never a manifest attribute, because the app is PIN-locked and only *calls* may show over the keyguard.
- The incoming-call notification is a **`NotificationCompat.CallStyle`** (`forIncomingCall`) with `VISIBILITY_PUBLIC`: from Android 12 on that is what gets the call treatment and real پاسخ/رد buttons on the lock screen, so the call stays answerable even when the OEM throttles the full-screen intent. `onCallAdded` also calls `bringActivityToFront()` for a backgrounded ringing call for the same reason.
- Once the call screen is actually up, `MainActivity.onResume` calls `CallInCallService.silenceIncomingNotification()`, which re-posts the same notification on the silent channel. Without it a locked phone shows *both* the heads-up card and the call screen; Google Phone shows only the screen and keeps a shade entry.
- `CallHandler` actions prefer `CallInCallService.currentCall` (telecom) and fall back to the legacy `CallConnection` (VoIP path). Mute/speaker go through `InCallService.setMuted`/`setAudioRoute` — AudioManager alone does not affect telecom-managed calls. DTMF uses `Call.playDtmfTone` (remote) plus a local ToneGenerator beep.
- **NEVER request ROLE_DIALER unless `CallInCallService` is declared and functional** — incoming calls would have no UI at all.

**Role prompts** (`DefaultAppGate`, `lib/core/widgets/default_app_gate.dart`, wraps `MainNavigation` inside `PermissionGate`): a Google-Messages/Phone-style request page, SMS first then dialer. `PermissionGate` NEVER fires a role request itself — the system sheet only opens on the user's tap, which is what makes re-asking safe (Android permanently auto-denies a role after two refusals of the *system* sheet, so the nagging has to live in our own UI).

- It re-checks on every `resumed`, so making another app default elsewhere and coming back asks again; «فعلاً نه» only lasts until the next resume.
- Before the app has been shown once it renders in place; after that it is **pushed as a route** on the root navigator — an inline widget would sit under any conversation/contact page already pushed there.
- On acquiring both roles it dispatches `SyncDeviceMessages` + `SyncCallLogs` + `RefreshContacts` (not `LoadContacts` — the cache predates the role change).
- The inbox banner (SMS) and `openDefaultAppsSettings` remain as the alternate entry points.

### SMS notifications (single native pipeline)

ALL incoming-SMS notifications are posted natively by `SmsNotifier` — from the live dynamic receiver (`SmsHandler`) and the cold-start `IncomingSmsReceiver` alike. The Dart `NotificationService` posts SMS notifications ONLY in the rare telephony-fallback path; never add a second Dart-side notification to the native event path (it would duplicate).

- Actions are fully native (`SmsNotificationActionReceiver`): inline reply via RemoteInput (sends with SmsManager + provider write-through + app-DB insert) and mark-read (direct DB update). They work with the app dead.
- Notifications are tagged with the threadId; opening a conversation calls `clearThreadNotifications` and `setVisibleThread` over the intents channel — `SmsNotifier` suppresses notifications for the visible thread while the activity is resumed.
- Tap deep-links: the launch intent carries a `threadId` extra → `DeepLinkService` (cold start: `consumeInitialThreadId` in MainNavigation; warm: `onNewIntent` → `openThread`). Registered post-auth so a tap never bypasses the app lock.
- Blocked numbers are enforced in BOTH receive paths natively (`BlockedNumbers.isBlocked` mirrors `PhoneNormalizer`) and in the Dart listeners; `SmsDeliverReceiver` also skips the provider write, and `CallInCallService` rejects ringing calls from blocked numbers before any UI. Missed calls post a native «تماس بی‌پاسخ» notification (default-dialer duty).

### Emoji panel

`EmojiPanel` (`messages/screens/widgets/emoji_panel.dart`) is the composer's emoji keyboard: category strip, one continuous scroll with inline headings, «اخیر» fed by what the user picks (SharedPreferences), skin-tone variants on long-press, and its own backspace. It replaced a flat 130-emoji grid from which a flag or a vehicle was simply unreachable.

- **Closing the panel must open the keyboard.** `ConversationScreen` owns `_composerFocus` and `_toggleStickers` does `requestFocus()` **plus `SystemChannels.textInput.invokeMethod('TextInput.show')`** — the node can still hold focus while the panel is up, and a no-op focus request does not raise the keyboard. The button showed a keyboard glyph but only closed the grid, leaving the user with neither.
- Focusing the text field closes the panel (`_onComposerFocusChanged`), so the two are never stacked.
- **Panel height.** Three rules, each of which was a bug:
  1. The keyboard height is only recorded while the inset is **rising** and the field **holds focus**. `viewInsets` is animated and reports every value on the way down too, so recording those made the *second* open take the height of a mid-dismissal frame (~130 px).
  2. Never `clamp` the result. The measured height climbs through the opening animation, so `clamp(220, 130)` (lower > upper) throws — and this is computed on every composer build, panel open or not, which turned the whole screen white for the length of the animation.
  3. The drawn height is the target **minus the inset the keyboard is still covering**. The panel appears immediately while the keyboard slides out over ~200 ms; a full-height panel plus the residual inset is more than the screen holds → `RenderFlex` overflow. Subtracting keeps the total constant and reads as a reveal.
- `EmojiPanel` therefore lays its contents out at `_kLayoutHeight` or more and clips to the height it was given (`OverflowBox` inside the clipping `Container`) — strip + footer + grid cannot lay out below ~84 px.
- The measured height is `static`, so a freshly opened conversation already knows it instead of falling back to the default.
- The active tab is a `ValueNotifier`, not `setState`: it changes continuously while scrolling and rebuilding the panel would rebuild every grid sliver.
- Skin tones: the modifier goes straight after the base code point and **replaces** a following `FE0F` (✌️ is `270C FE0F`; its toned form is `270C 1F3FD`, not `270C FE0F 1F3FD`, which renders a stray colour swatch).

### Delivery status (bubble ticks)

`SmsService.sendSms` generates the message UUID BEFORE the native send and passes it as `trackingId`; the native sent/delivered PendingIntents carry it back through the SMS EventChannel as typed `{"type":"status"}` events (incoming SMS events carry `"type":"received"`). `SmsService` updates the DB row and broadcasts on the static `onMessageStatusChanged`; `MessageBloc.MessageStatusChanged` swaps the message in the open conversation in place (⏱ pending → ✓ sent → ✓✓ delivered / failed with retry).

### Long-press & selection

Long-press is the *same gesture everywhere*, matching Google Messages / Phone / Contacts:

- **Chat bubble → lift, zoom, select text.** `MessageBubble` (stateful, holds a `GlobalKey` on its box) measures the bubble's global rect *and* where inside it the finger landed, then hands both to `showMessageActionOverlay` (`widgets/message_action_overlay.dart`). The overlay is a `PopupRoute` that blurs the backdrop, animates the bubble from its list position to a lifted one at `_kZoom`, and makes the body selectable — the Telegram flow. The action card (ستاره / کپی / هدایت / اطلاعات / انتخاب / حذف) hangs off the bubble's own edge.
  - There is deliberately **no «انتخاب متن» menu row and no select-text dialog** any more; selection happens on the lifted bubble itself.
  - Nothing is selected when the overlay opens — the lift is **only** a zoom. A long-press *inside* the lifted bubble then selects the word under the finger and the handles widen it.
  - The lifted body is `SelectableBubbleText`, which wraps the **same `LinkifiedText` widget** the flat bubble renders in a `SelectionArea`. Do not swap that for a `TextField`/`SelectableText` copy: those lay out through `RenderEditable`, which reserves a caret margin, so the text re-wrapped one line longer than the original and the lifted bubble collided with the action menu. Same widget in, same wrapping out — which is also what lets the overlay position the menu from `anchor.height`.
  - The selection toolbar **relabels `SelectableRegionState.contextMenuButtonItems`** («کپی» / «انتخاب همه») rather than re-implementing copy; the app ships no Persian `MaterialLocalizations`, so the stock labels would be English. `copySelection` is deprecated — go through the button items.
  - The bubble box is rendered by `MessageBubbleBody`, shared by the list and the overlay — the zoomed copy must be the *same* widget or the lift visibly jumps. `LinkifiedText.buildSpan` is likewise shared so links look identical in the selectable copy (inert there).
  - The scrim is inside the page (it has to be blurred) and is wrapped in `IgnorePointer` so the dismissing tap reaches the route's own modal barrier underneath.
  - The app ships no Persian `MaterialLocalizations`, so the selection toolbar's labels («کپی», «انتخاب همه») are supplied by hand in `MessageBubbleBody._selectionToolbar`.
- **Thread row → multi-select**, not a sheet (`showThreadOptionsSheet` was deleted). Every action it used to hold lives in `MessagesSelectionAppBar`. Draft-only rows are synthetic (no conversation behind them), so their long-press still just discards the draft.
- **Contact row → multi-select** with a contextual bar (count · ستاره · اشتراک‌گذاری · حذف · انتخاب همه). Deletes go to the DEVICE address book via `FlutterContacts.deleteContacts`, then invalidate `ContactRepository` + `LazyContactAvatar` caches and dispatch `RefreshContacts`. Share is single-selection only — the platform sheet takes one contact.
- **Draft card → multi-select**, **category row → multi-select** (سنجاق · انتقال/تغییر نام · حذف · انتخاب همه). Both use the shared `SelectionAppBar` + `SelectionCheck` from `core/widgets/selection_app_bar.dart` — the inbox keeps its own **sliver** bar (`MessagesSelectionAppBar`) only because its header collapses. The virtual «همه» / «بدون دسته‌بندی» rows are never selectable: there is no table row behind them to rename, delete or pin. Multi-select is off in the drafts **picker** (`pickMode`).
- Every long-press fires `HapticFeedback.mediumImpact()`.

**Tapping a phone number inside a message** opens `showPhoneActionSheet` (تماس / ارسال پیامک / مشاهده مخاطب or افزودن به مخاطبین / کپی شماره). It must NEVER launch a `tel:` intent: this app is the default dialer, so the intent resolves back into its own process — the UI froze for ~9 s, swallowed the gesture and could take the activity down. The contact lookup runs *after* the sheet is on screen (cold address book) and is wrapped in a try/catch so a missing permission still leaves call/SMS/save usable.

### MessageBloc state guards

- `LoadThreads` does **not** emit `MessageLoading` if the current state is already `ThreadsLoaded` or `MessagesLoaded` — this prevents the chat screen going blank when a background SMS triggers a thread refresh.
- `_cachedPhoneToName` is built once per session and reused by `_resolveContactNames` to enrich threads with device contact names without hitting the contact store on every tab switch. While that map is still cold `_emitThreads` emits the rows **twice** — once bare, once named — rather than holding the inbox back for an address-book read that may be queued behind another `DeviceSyncQueue` job.
- `LoadMoreThreads` / `LoadMoreMessages` carry an in-flight flag (`_loadingMoreThreads`, `_loadingMoreMessages`). The `hasMore` guard alone is not enough: it only flips once the previous page *returned*, so a fast fling dispatched one event per scroll notification and the bloc ran a dozen paged queries back to back — the multi-second stall while scrolling the inbox.
- `MessageRepository.getAllThreads` pages inside a `page` CTE that carries nothing but (thread_id, last_ts, is_pinned); the per-thread work (last-message rowid pick, unread count) runs only on the rows that survived `LIMIT`. Flattening it back re-introduces a correlated subquery per message row of the whole table.
- **A refresh must not shrink the paged-in inbox.** `_loadedThreadCount` / `_loadedArchivedCount` (kept apart per inbox, updated in `_emitThreads` and `_onLoadMoreThreads`) raise the limit of any `LoadThreads` at offset 0 to however many rows are already on screen. A plain `LoadThreads()` carries the default limit of 50 — returning from a conversation, resume or a send used to cut a 200-row list back to 50 underneath the user, which collapsed the scroll position to the top.

**Inbox scroll position.** `MessagesListScreen` caches the last `ThreadsLoaded` it painted (`_lastInbox`) and keeps rendering it while the (shared) bloc sits in a state the inbox can't paint — `MessagesLoaded` for the open conversation, `ThreadsLoaded(archived: true)` for the archived screen. Swapping the list for a `SliverFillRemaining` spinner in those moments tore the sliver down and with it the scroll offset, so every return from a conversation landed at the top of the inbox. The selection actions read `_lastInbox` for the same reason.

### Authentication & app lock

- Auth type (PIN or pattern) and credentials are stored in `flutter_secure_storage`.
- `AppLockService` tracks the locked/unlocked state in memory.
- `AppLockWrapper` listens for `AppLifecycleState` changes and can re-lock the app on resume.

### RTL / Persian

All UI text is Persian. Wrap any new screen or dialog root with `Directionality(textDirection: TextDirection.rtl, ...)` or use `RtlAppBar`. The `PersianUtils` class and `AppConstants.persianNumbers` handle Persian digit conversion.
