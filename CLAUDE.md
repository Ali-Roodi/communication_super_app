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
- **Nothing on the way in draws a spinner.** The two gates before the app — the permission check and the auth-state read — render a blank `Scaffold`, and `hasAllRequiredPermissions` runs its four reads with `Future.wait` instead of one after another. Each resolves in a few frames, so a spinner there does not inform anybody; it just makes every single launch look like it is loading, which is exactly how it was reported. Measured cold start on the test device: ~1.8 s from `am start` to a painted, populated «اخیر», no dropped frames.
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

Single SQLite database (`communication_app.db`, version 21) managed by `DatabaseHelper` singleton (`lib/core/database/`). Tables: `contacts`, `messages`, `call_logs`, `favorites`, `blocked_numbers`, `archived_threads`, `pinned_threads`, `message_categories`, `drafts`, `message_templates`, `scheduled_messages`, `thread_sim`, `speed_dial`. Constants in `AppConstants`.

**Schema invariants:**
- `messages.thread_id` is the digits-only normalized phone number.
- `messages` has a unique index on `(phone_number, body, timestamp, type)` (DB v3) — all batch inserts must use `ConflictAlgorithm.ignore` to silently skip duplicates.
- `messages.is_read` marks unread messages; every *sent* row is inserted with `is_read = 1` (composer, scheduled worker, device import alike). The inbox's `unread_count` therefore counts unread rows of **any** type — it must not filter on `type = 'received'`, or «علامت‌گذاری به‌عنوان نخوانده» silently does nothing on a thread the user only ever sent to (or whose received rows are all soft-deleted): `markThreadAsUnread` flags the received rows, and falls back to the newest non-deleted row of any type when there are none. `markThreadAsRead` clears the flag on every type for the same reason — filtering it would strand such a thread bold for ever.
- `drafts.is_pinned` / `message_categories.is_pinned` (DB v14) float a row to the top of its list. `DraftRepository.upsertDraft` REPLACEs the row, so `DraftBloc._onSave` re-reads the existing draft and carries the flag over — without that, editing a draft silently unpinned it.
- `blocked_numbers.normalized` is the **canonical thread id** (`09xxxxxxxxx`) — the same key `messages.thread_id`, `PhoneNormalizer.toThreadId` and the native `BlockedNumbers.normalizeToThreadId` produce. It used to be a raw digits-only strip of whatever string the caller happened to hold, which is why **blocking did nothing at all**: a number blocked from a conversation was stored as `989121234567` (the address as the carrier delivered it) while every lookup — Dart and Kotlin alike — asked for `09121234567`. The row was there and the check never found it. Only `BlockedNumberModel.normalize` may produce this column; DB v16 rewrites the rows written before it (in Dart — `toThreadId` is not expressible in the SQL a migration can run — deduplicating on collision, oldest row wins, because the column is UNIQUE).
- `favorites.normalized` is the **same canonical key** (`PhoneNormalizer.toNational`), for the same reason and after the same bug: it is a UNIQUE column, and while it held a raw digits-only strip one person could be starred twice — once from a call log carrying `+989121234567`, once from Contacts carrying `09121234567` — with `isFavorite` answering false on whichever surface asked with the other form. DB v19 rewrites the old rows (dedupe, oldest wins). `FavoriteModel.normalize` returns **empty** for a string with no digits, and `FavoritesRepository` normalizes inside `isFavorite`/`removeFavorite` so a caller holding a display number cannot miss the row.
- The same canonicalization applies to the two grouping keys in «اخیر»: `CallHistoryScreen._normalize` (which decides whether consecutive calls collapse into one «(۲)» row) and `call_detail_sheet._normalize` (which filters «تماس‌ها با این مخاطب»). Both were digits-only strips and both split one contact in two whenever the carrier changed format between calls.
- `blocked_numbers.is_spam` / `reported_at` (DB v16) mark «مسدود کردن و گزارش هرزنامه» as opposed to a plain block. One table, not two lists: Google keeps both in the same page and only one of them is a report.
- A migration that ALTERs a table an earlier step of the *same* upgrade may have just created at its newest shape must guard on `_columnsOf` — an unconditional `ADD COLUMN` there aborts the whole upgrade. This is real for `blocked_numbers`: `oldVersion < 5` creates it, `oldVersion < 16` alters it.
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

### Template SMS wire format

A filled built-in template is mostly boilerplate the receiver already has, and
Persian SMS fits 70 UCS-2 characters per part. So a **built-in** template does
not ship its prose — it ships a header naming the template plus the answers:

```text
[#T1:mtg:1]علی|جلسه هفتگی|۱۴۰۵/۰۵/۲۰|۱۰:۳۰|اتاق ۳   (49 chars)
علی عزیز⏎جلسه جلسه هفتگی در مورخه ۱۴۰۵/۰۵/۲۰ ساعت ۱۰:۳۰ در محل اتاق ۳ برقرار می‌باشد.   (85)
```

`#T1` = format version 1 · `mtg` = `BuiltInTemplate.code` · `1` = flag bits (bit
0: the first segment is the «<نام> عزیز» greeting) · then one segment per
placeholder in `BuiltInTemplate.tokens` order, `\` `|` and newlines escaped,
trailing blanks dropped. `TemplateWire.encode` returns **null** — plain text goes
out instead — for a user-authored template, an edited built-in, a template with
no placeholders, or when the payload would not actually be shorter than the
prose (`[#T1:cng:0]سال نو` wins; a one-placeholder template with a long answer
does not). A receiver without this app sees the header and the few words that
were typed; that is the accepted trade, and the prose-free field list is the
seam the next phase (encrypted SMS) plugs into.

- **Bound to compiled-in constants, never to DB rows.** The built-ins exist twice:
  as rows in `message_templates` (editable, pinnable, deletable) and as
  `BuiltInTemplates.all`. The wire carries a `code` into the *constants*, because
  two phones do not have the same rows — if it carried a row id, one side editing
  «دعوت‌نامه جلسه» would silently rewrite the other side's incoming messages.
  `BuiltInTemplates.of` therefore returns the built-in only while the row's body
  is still pristine; an edited one falls back to full text. **Never reuse or
  repurpose a `code`** — old messages on someone's phone still decode through it.
- **User templates are excluded on purpose.** There is no backend, so the other
  phone cannot know a body the user invented. They send their full text, as
  before.
- **The DB stores the wire; decoding is render-time only.** The row must hold the
  body exactly as it went over the air — that is what `content://sms` holds and
  what the mirror-sync diffs against (body+timestamp fuzzy match, stale-row
  diff). So no stored row is ever rewritten: every surface that *displays* a body
  goes through `TemplateWire.displayText` — bubble, inbox preview, «ستاره‌دار»,
  the Dart fallback notification — and copy / forward / share carry the display
  text, never the payload.
- **The composer never shows the payload.** `TemplateFillResult` carries the
  human text *and* the payload; `ConversationScreen` holds the pair and transmits
  the payload only while the field is still character-identical to that text (one
  edit and the words on screen are what the user means). `_outgoingBody` feeds
  both the send and the schedule path, so a scheduled template travels compact
  too. `ComposerDraftStore` persists only the visible text, so a draft restored
  later sends as plain text — correct, the payload is not recoverable from it.
- **A decoded bubble is just a bubble.** It briefly carried a «قالب: <عنوان>»
  chip opening a read-only copy of the fill form; that was removed on the owner's
  call — the rebuilt text already says everything the template said, so the chip
  was a row of furniture under every template message that led nowhere useful.
  `TemplateFillScreen` therefore has no reader mode: it only composes.
- **Kotlin mirror:** `android/.../TemplateWire.kt` ports `decode` +
  `TemplateEngine.render` (non-preview) + the catalogue, and `SmsNotifier` runs
  every incoming body through it — all incoming-SMS notifications are posted
  natively, so without it the shade showed the raw payload while the chat showed
  the message. Header regex, version check, escaping, segment splitting,
  placeholder order and every template body must match the Dart character for
  character; **change the two together**, the same contract `ScheduledSmsWorker`
  has with `scheduled_message_model.dart`. A mismatch does not fail loudly, it
  renders a *different* message than the sender wrote. Only the receive half is
  ported (encoding is always Dart), and nothing native rewrites what is written
  to `content://sms` or to the app DB.

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

**Mirror-sync (`SmsService.syncDeviceMessages`)** replaced the old one-shot import. Runs once per session on `LoadThreads` and silently on resume (`SyncDeviceMessages` event, no loading state). Steps: read the **full** id list of each box (`querySmsIds`, `DATE DESC`), subtract the `device_sms_id`s already known (`MessageRepository.knownDeviceSmsIds`), then page the *missing* ids only (`querySmsByIds`, `_importPageSize`) through `MessageRepository.reconcileDeviceRows` (known-id skip → exact content match → **fuzzy ±2 min match** — needed because live-received rows store the SMS-PDU timestamp while the provider stores receive time → insert), then delete local rows whose `device_sms_id` vanished from the same id sets.

- **It used to cap the *content* read at 500 rows per box, and that is why old received messages were missing.** The inbox fills far faster than the sent box, so on a real phone the cap reached back ~6 weeks on one side and years on the other: scrolling up showed only the user's own messages. The cap is gone — the id list is cheap, the bodies are fetched only for rows that are genuinely new, and each page yields.
- The pages report progress (`onProgress` → `MessageBloc._onSyncProgress`, throttled to 2 s), so the first import fills the inbox as it goes instead of finishing into an empty screen.

**The sync NEVER blocks a paint or the bloc's event queue.** `MessageBloc._startBackgroundSync` runs it as a detached future and only its completion comes back as `DeviceSyncFinished`; `_onLoadThreads` paints from the local mirror first. Awaiting it inside the handler cost ~5 s of spinner on a cold start *and* queued every other event (opening a conversation) behind it. Consequences to preserve: `_hasImported` is set in `_onDeviceSyncFinished` (only on success, so a permission-denied first run retries), `listenToIncomingSms()` starts *before* the sync (messages arriving during it used to have no listener), and the "no permission and nothing local" error is raised from `DeviceSyncFinished(ok: false)`, not from the load.

The stale-row diff (`removeRowsMissingFromDevice`) runs **inside SQLite** against a temp table of provider ids — pulling every local row over the platform channel to subtract in Dart is what jammed the UI thread mid-scroll on a full phone.

**Deletes are global:** `MessageBloc` delete events go through `SmsService.deleteMessagesGlobally` / `deleteThreadGlobally` (provider rows first — by `device_sms_id`, falling back to body+timestamp±10 s match; thread delete matches addresses by last-10-digits in `SmsHandler.deleteSmsThreadFromProvider`), then the local store. Never delete local-only; the mirror-sync would just be out of sync with the phone.

**The local half of a delete must be a SOFT delete** (`softDeleteMessages` / `softDeleteThread`). The tombstone keeps the row's `device_sms_id`, and `_knownDeviceSmsIds` (used by `reconcileDeviceRows`) deliberately ignores `is_deleted`, so a deleted message is recognised and skipped instead of re-imported. A hard delete looked fine until the next sync: the provider delete is a **no-op unless the app holds the SMS role**, so everything came back — usually noticed after an app restart. `deleteThread` (hard) is left only for local-only data and tests.

**Call-log sync:** `CallLogSyncHandler.kt` registers a ContentObserver on `CallLog.Calls` and pushes debounced change events (`call_log_events` EventChannel) → `CallLogBloc` runs a silent `SyncCallLogs` (no flicker, keeps pagination). `CallLogService.syncFromDevice()` mirrors: upsert device rows, delete numeric-id local rows missing from the device. In-app deletes use `deleteCallLogsGlobally` (provider delete via `WRITE_CALL_LOG`, then local). `NativeCallLogService.initialize()` is re-invoked on `LoadCallLogs` because the first observer registration can predate the READ_CALL_LOG grant.

**Contact extras / «برنامه‌های متصل»:** `ContactExtrasHandler.kt` reads the third-party Data rows on a contact (rows whose MIME type is outside the standard set). Two things this depends on, both easy to break: the manifest `<queries>` entries for `android.accounts.AccountAuthenticator` and `VIEW`+`vnd.android.cursor.item/*` (targetSdk 30+ package visibility otherwise hides the authenticator, `packageForAccountType` returns null and the whole section renders empty), and resolving the row's action to a **concrete component** before launching — messengers register several activity-aliases per custom MIME type, so an implicit intent (even with `setPackage`) pops an "Open with" sheet listing the same app twice.

**Merging duplicates is `AggregationExceptions`, not a rewrite.** `ContactLinkHandler.kt` (+ `ContactLinkService`) writes `TYPE_KEEP_TOGETHER` over every pair of the raw contacts behind the selected contacts — `flutter_contacts` cannot do this, and "write one contact and delete the others" is a different, lossy thing: nothing is copied, nothing is deleted, each account keeps its own row, and `unlink` (`TYPE_KEEP_SEPARATE`, so the provider's matcher cannot silently re-aggregate) takes it apart again. The row is written with `newUpdate` — the provider upserts on the (raw1, raw2) key and an insert throws.

- Three entry points: the contacts selection bar («ادغام», hidden when the selection includes a SIM contact — an ADN record has no ContactsContract row to aggregate), `DuplicateContactsScreen` (union-find over *shared number* **or** *same folded name*; both rules are needed, and grouping has to be transitive), and «جدا کردن مخاطب‌های پیوندشده» on the contact page, shown only when `rawContactCount > 1`.
- The linked id is **not** necessarily one of the inputs — the provider re-aggregates and picks — so callers refresh instead of assuming.
- **The merge asks whose name and photo survive** (`showMergeContactsDialog` → `link(ids, primaryContactId:)`). Aggregation alone does not decide that: the provider picks a display name of its own, so merging «علی» with a row saved as a number silently renamed the person. `ContactLinkHandler` captures the chosen contact's raw ids *before* aggregating and then sets `IS_SUPER_PRIMARY`/`IS_PRIMARY` on its StructuredName and Photo rows. Both entry points (selection bar, `DuplicateContactsScreen`) go through the dialog; it defaults to the longest name.

**Labels («برچسب‌ها») are editable, and the provider's group list is not the user's.** Every account carries its own «Family»/«Coworkers», and a Google contact also sits in «My Contacts» and «Starred in Android». `ContactGroupsService` therefore exposes a `ContactLabel` = *name* + every group id carrying it: one row on screen, reads and writes fanned out, internal names hidden (`isInternal` / `visibleNames`). Without that the labels screen listed «Coworkers» three times.

**Memberships are written natively, NOT through `flutter_contacts`** (`ContactGroupsHandler.kt`, channel `…/contact_groups`). A `Groups` row and a `RawContacts` row each belong to an account and a `GroupMembership` is only valid when **the two match**; the plugin's `insertGroup` writes a TITLE and no account at all, so every label made through it was account-less, every membership written against it meaningless, and the label came back empty — which is the whole of the "I save a contact into a label and the label is empty" report. `applyLabels` / `addToLabel` / `removeFromLabel` / `memberIds` / `createLabel` replace it; `AddEditContactScreen` saves the contact with a plain `update()`/`insert()` and then calls `applyLabels`.

- **The account a new label goes into is ranked, not just "the busiest"** (`busiestAccount` + `accountRank`). A messenger that mirrors the whole address book into its own sync account outnumbers the phone's real store — measured on the test device, 298 rows in `ir.eitaa.messenger` against 158 in `vnd.sec.contact.phone` — so plain "busiest" created every label inside a **read-only copy** its adapter may wipe. Rank comes from `ContentResolver.getSyncAdapterTypes()` (no permission needed): no contacts adapter registered = a device-local store and the best home (2), an adapter that `supportsUploading` = a real cloud account (1), a download-only adapter = a mirror (0). SIM accounts are excluded — an ADN record has no `Groups` row to belong to.
- **A label lives in as many accounts as it has members.** `applyLabels` writes each membership against a raw contact **in the group's own account**, creating the group in that account when it is not there yet, and `memberIds` matches by *title* across accounts. So one «Family» on screen is routinely several `Groups` rows underneath, and that is correct.
- `groupFor` prefers an id the contact already carries, so saving does not move the tag to another account.
- The «برچسب‌ها» row sits in the editor's main form, **not** behind «فیلدهای بیشتر» — buried there nobody found it, which is most of why labels went unused.
- A label page («برچسب‌ها» → tap) is where a label is *used*: «افزودن مخاطب» (contact picker → `addToLabel`) and «پیامک گروهی» (→ `BroadcastComposeScreen`) live in its app bar, and deleting a label asks first — the membership rows go with it and re-creating the name brings nobody back.

**The phone field in the editor is LTR** (`Directionality.ltr` around the `TextFormField`, alone on this form). A phone number is left-to-right content: in the page's RTL direction the digits laid out right-aligned with the caret on the wrong side, so typing read as if the number were going in backwards and a leading `+` landed at the far end. The *detail* page's `_phoneTile` is deliberately left as it is — it renders LTR text right-aligned inside the RTL row and that is correct there.

**Contacts:** all writes go straight to the device address book via `flutter_contacts` (`AddEditContactScreen`); there are deliberately NO create/update/delete bloc events. `ContactRepository.getContactByPhoneNumber` resolves against the device-contact cache (normalized-number match) — the local `contacts` table is legacy and nothing writes to it.

The static contact cache carries a **generation counter**: `invalidateCache()` / `forceRefresh` bump it, and a read that started before the bump refuses to publish its (pre-write) snapshot. Saving a contact invalidates the cache while the `FlutterContacts.addListener` refresh already has a read in flight — without the guard that stale snapshot won, and a contact added from a call log stayed missing from the list *and* the search until the next app start.

**An edit is visible on the page you edited from.** Two halves, and both were missing: `DeviceContactDetailScreen` derives its title from the contact it *re-read* after the editor pops (through `ContactNameStyle.format`, so it obeys «قالب نام»), and `LazyContactAvatar` carries a `static ValueNotifier<int> generation` bumped inside `invalidateCache()` — every mounted avatar listens and reloads its own bytes. Without the second one the name updated and the photo did not, which looks worse than neither. Before this, a rename or a new photo only appeared after leaving the contacts screen and coming back.

### Contact name format & ordering

«قالب نام» and «مرتب‌سازی بر اساس» are applied **where the ContactModel is built** (`ContactRepository.getDeviceContacts`), not where a row is drawn: the name that comes out is what the list, the search, the dialer suggestions, the call-log resolution and the fast-scroll index all see, so they cannot disagree. `ContactNameStyle` (`core/utils/`) is the static mirror of the two settings — same pattern as `DateFormatter.calendar`, for the same reason (a plain repository has no `BuildContext`).

- The formatted name and the order are baked into the cache, so a setting change has to force a re-read: `ContactNameStyle.apply` sets the statics **then** emits on `onChanged`, and `ContactBloc` listens and dispatches `RefreshContacts` — the same shape as its `SimService.onChanged` subscription. Emitting before the statics are set would re-cache the old names.
- `ContactModel` keeps `firstName`/`lastName` beside the rendered `name`, and `sortName` is what the address book is **ordered and bucketed** by: under «نام خانوادگی» a row has to appear under the family name's section letter, which is not the letter its displayed name starts with. Both parts are null for a SIM (ADN) record or a one-word/company row, and every path falls back to `name`.
- **The list is sorted by us, not by the provider** (`ContactRepository._sorted`). Three things need that and none come free: family-name ordering is not an order `ContactsContract` was asked for, the SIM cards' contacts are *appended* after the phone's (they sat in a clump at the bottom), and the fast-scroll bar jumps to an offset accumulated from the section ranks — a list ordered against those ranks lands the jump on the wrong name.
- **`PersianCollator` (`core/utils/persian_alphabet.dart`) is the ordering.** `String.compareTo` is UTF-16 order and the Persian alphabet is not in UTF-16 order — پ چ ژ ک گ all sit outside the ب…ی run — so a naive sort scatters them. The key maps each `SearchText.fold`ed character onto its rank, prefixed by the section rank so list order and index bar can never diverge, and is built **once per contact** (decorate–sort–undecorate); building it inside the comparator folds every name O(log n) times over a whole address book.
- The alphabet, the letter aliases and `sectionLetterFor` live in that same file because `ContactsListScreen` and the repository must use one table.

### Settings

Every switch on a settings page is read by something. That was not true, and the ones that were not were **removed, not left on screen**: TTY / hearing-aid / noise-reduction (the whole «دسترس‌پذیری» page), «شناسه تماس‌گیرنده و هرزتماس» (there is no caller-ID database and no spam service — «هرزنامه و مسدودشده» is the thing that actually works), «پاسخ‌های سریع» (the list is now a constant in `incoming_call_screen.dart`; the reject-with-SMS sheet and its «نوشتن پیام...» escape hatch are unchanged), «صدای صفحه‌کلید» and «لرزش هنگام تماس», and «مجوزهای متن‌باز». `SettingsBloc._retiredKeys` drops their SharedPreferences keys once on load so an upgraded install does not carry them.

- **The call ringtone and vibrate-on-ring are Telecom's, not this app's.** It holds the dialer role but never plays the ringer, so «صدا و لرزش» *links* to `ACTION_SOUND_SETTINGS` (`CallHandler.openSoundSettings`, tried-not-probed: `resolveActivity` is filtered by package visibility) instead of offering a switch it could not honour. The two switches left on that page — dialpad tone and dialpad haptic — are both read in `_KeyGrid.press`.
- **«باز کردن صفحه‌کلید هنگام اجرای برنامه» means the app, not the dialer**: the keypad is a bottom sheet opened from the FAB, so app-launch is the only moment there is to pop it. `MainNavigation` does it from the same post-frame callback that consumes the notification deep link (which wins), and skips it when its route is no longer current — an incoming call during launch must not get a modal sheet dropped over it. It reads the flag with `SettingsBloc.readShowDialpadOnStart()` rather than from state, because `LoadSettings` is async and may not have landed by the first frame.
- The version row reads `package_info_plus`; a hardcoded string is wrong the first release after it is written and the one place it matters is a bug report.

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

### Message search

`MessageRepository.searchMessages` / `searchThreads` (with `models/message_search_query.dart`) are the only message search. They match the body of **any** message of **any type** — the previous "search" filtered the paged-in inbox list on `thread.lastMessage`, i.e. the single newest message of each *loaded* thread, which is usually the received one: that is the whole of "it never finds my own messages". It also could not see a conversation that had not been scrolled into memory, and it bypassed `SearchText`.

- **Two stages, and the SQL stage may only ever be too wide.** There is no FTS index, so the prefilter is an AND over a few folded query characters, each an OR over every character that folds onto it, and the authoritative answer is `SearchText.nameContains` in Dart over the survivors. The pre-image table is **derived at runtime from `SearchText.fold` itself**, not copied from its private maps — a copy would drift and start producing false negatives. Terms also OR their `toUpperCase()`, because SQLite's `LIKE` is case-insensitive for ASCII only.
- **There are two paths, and they must agree.** The fast one is an **FTS5 index with the `trigram` tokenizer** (`message_search`, DB v18) holding `SearchText.foldTight(TemplateWire.displayText(body))` per message. Trigram is the only tokenizer that makes FTS5 a real *substring* index — the default ones match whole tokens or prefixes and would miss «جلس» inside «مجلس», i.e. produce false negatives. Space-stripped folded text is used because `nameContains` treats spacing as optional, and a substring test over space-stripped text is a provable superset of that rule; `matchesBody` still settles every candidate, exactly as it settles the `LIKE` prefilter's.
- **Bundling SQLite to turn the index on was considered and declined (2026-08-09).** Measured on a 50k-message mailbox: the scan answers a rare needle in 68 ms and the index in 1 ms — but the scan already answers a common needle in 7 ms, the one-off backfill costs ~2.6 s (≈10 s on a phone), and the limitation that actually bites (a one- or two-character query falling back to "the most recent N messages") is **not fixable by trigram at all**, since a trigram cannot speak about two characters. Against that: the Kotlin side opens this same database file with `android.database.sqlite` from code that runs **while the app's process is dead** (cold-start SMS receiver, scheduled worker, notification reply, the in-call blocked-number lookup), so two engines would have to agree on WAL and locking — and a `database is locked` there is a dropped SMS or a block that does not hold. Not worth 68 ms → 1 ms. Re-open it only on a *measurement* from a real large mailbox, with a Dart/Kotlin concurrency test on one file as the precondition.
- **The index is a speed switch, never a correctness one — and on Android it is currently OFF.** `sqflite` uses the OS's SQLite, and Android's system build **does not include the FTS5 module at all** (verified on Android 16: `no such module: fts5`), never mind the 3.34 trigram threshold. So `DatabaseHelper._createMessageSearchFts` fails, `messageSearchFtsReady` stays false, and every search takes the scan path. The machinery is kept because it activates the moment the app bundles its own SQLite (`sqlite3_flutter_libs` + ffi) — which is a storage-engine change the Kotlin side reads the same file with, so it is a deliberate decision, not a cleanup. FTS4 is not a substitute: it ships in the system build but has no trigram tokenizer, so it cannot do substring matching and would become a source of false negatives.
- It is used only when three things hold: the index exists (above), the needle is ≥ 3 characters (a trigram cannot speak about two), and **the index has no backlog** (`MessageRepository.searchIndexReady`). That last one is the subtle one: a half-filled index answers confidently and silently omits what it has not folded yet, so while anything is unindexed *every* search takes the scan path. Existing mailboxes therefore behave exactly as before until the backfill finishes, then get faster.
- **The indexed path is paged too.** Measured on a 50k-message mailbox: the scan
  answers a *rare* needle in 68 ms and the index in 1 ms, but a needle as common
  as «سلام» matched thousands of rows, and an un-paged FTS query that fetched and
  sorted them all before Dart filtered came in at 94 ms against the scan's 7 ms —
  the scan wins there purely by stopping once the caller has its screenful. Both
  paths therefore page at `_kSearchPageSize` and stop on the same signal.
- **The indexer is the only writer, and it is self-healing.** `MessageRepository.syncSearchIndex` folds a bounded batch of rows with `search_indexed = 0`; `MessageBloc._drainSearchIndex` loops it after each mirror-sync, yielding between commits. Rows inserted **natively** (the scheduled worker, the notification quick-reply) never set the flag, which is exactly how they get found — no Kotlin mirror of `SearchText.fold` is needed. Each row is DELETEd from the index before being inserted, because SQLite reuses the rowid of a hard-deleted message and a stale entry would otherwise answer with text from a message that no longer exists.
- **Bounded, not free** on the fallback path. `LIKE '%x%'` cannot use an index, so the walk is newest-first over `idx_messages_search` (`is_deleted, timestamp DESC` — the filter first, so tombstones are seeked past rather than read and rejected), paged, and capped (`_kMaxPrefilteredRows`): a one- or two-character query degrades to "search the most recent N messages" rather than scanning a full mailbox on the UI isolate.
- **Number matching for threads runs in Dart**, one row per conversation. A `thread_id LIKE` prefilter provably *can* miss: `89121` matches the middle of the stored `+989121234567` while the thread id is `09121234567`.
- **Contact names are the caller's half.** They live in the device address book, not in any column, so the screen matches them over the whole book and passes the ids in as `alsoThreadIds`; that is what makes a thread findable by name before it has been paged in.
- **A compact template payload is admitted unconditionally** by the prefilter and settled on `TemplateWire.displayText` — the payload carries the answers but none of the template's prose, so the prefilter would otherwise reject a row whose rendered text plainly matches.
- `searchThreads` renders its hits *through* `getAllThreads(restrictToThreadIds:)` rather than a second query, so the last-message pick and the unread count cannot drift.
- The inbox search field is debounced and token-guarded, and while a query is live the list is **not** paged (`_onScroll` bails): search results are one answered query, not a page of the inbox.

### Block & report («هرزنامه و مسدودشده»)

Blocking was already enforced in four receive paths and still felt broken, for two independent reasons: the key never matched (see the `blocked_numbers.normalized` invariant above), and **nothing visible changed**. Both are fixed:

- **A blocked conversation leaves every list `getAllThreads` returns** — inbox, archive and search alike — via an indexed `NOT IN (SELECT normalized FROM blocked_numbers)` subquery, and lives in `SpamAndBlockedScreen` instead. That is the visible half of blocking, exactly as Google Messages moves the thread into «Spam & blocked». `includeBlocked: true` opts out. The conversation stays readable; opening it does not unblock anything.
- **One page, two entry points:** the inbox overflow menu (next to قالب‌ها / زمان‌بندی‌شده‌ها — buried under Settings it was three taps from the conversation it was about) and Settings → «هرزنامه و مسدودشده». The old settings-only `BlockedNumbersScreen` was deleted rather than kept alongside, so there is one list and not two that drift.
- **One gesture, asked once.** `showBlockNumberDialog` / `blockNumberWithConfirm` (`settings/screens/widgets/block_number_dialog.dart`) is the whole interaction — confirmation + «گزارش به‌عنوان هرزنامه» checkbox + undo — shared by the conversation menu, the spam prompt, the call-log row, the call-detail sheet, the contact page and the inbox selection bar. The checkbox defaults **on** for a number with no contact and **off** for a saved one: reporting someone in your own address book is nearly always a mis-tap.
- **`BlockedNumbersRepository.block` upgrades.** Reporting a number that is already blocked must set the flag rather than being swallowed by the UNIQUE constraint, and a later plain block never clears a report. «این هرزنامه نیست» (`clearReport`) drops the report and keeps the block.
- **The report is offered inside the conversation**, on an unsaved number that has actually written — a prompt row above the thread, dismissed for the visit either way. The overflow menu alone is not where anyone decides something is junk.
- Blocking from a conversation pops it: the thread is no longer in the list behind it.

### Transient confirmations

`showUndoSnack` (`core/widgets/undo_snack_bar.dart`) is the app's only snack bar carrying an action. **A `SnackBar` with an action is not guaranteed to time out**: `ScaffoldMessengerState` skips starting its dismissal timer while `MediaQuery.accessibleNavigation` is true, so with any accessibility service active «گفتگو بایگانی شد» sat on the inbox until something else replaced it. This helper owns its own `Timer` and hides the bar itself, so the 3-second window is authoritative whatever the platform reports — and it *shows* the countdown as a shrinking ring around «واگرد», because an undo the user cannot see expiring is a guessing game. `showCountdown: false` for an action that is a shortcut rather than an undo («تنظیمات»), where a ticking clock would imply a deadline that is not one.

### Keypad touch

`DialKey` fires **on touch-down, through a raw `Listener`** — not on an `InkWell` tap. The keypad lives inside a draggable modal bottom sheet, so a tap recognizer has to win a gesture arena against the sheet's vertical drag: dialing fast means each press carries a few pixels of movement, the drag claims the pointer, and the tap is never delivered — digits went missing exactly when typing quickly. A `Listener` is not an arena member, so its callbacks always arrive (and two thumbs can type at once).

Consequences to preserve:
- Long-press is a **timer started on down**, cancelled by a release or by sliding past the slop — a `GestureDetector` long-press would be back in the arena.
- The digit is already typed when a long-press fires, so `_longPressFor` **deletes it first** (`0` → «۰» then «+»; `1` → delete then voicemail).
- `DialerScreen` has **no top-level `BlocBuilder`**. Every keypress emits a state, and rebuilding the 12 animating keys plus the suggestion list between one finger-down and the next is exactly the work that made presses land late. Only `DialerNumberDisplay`, the suggestions and the call pill sit in (narrow, `buildWhen`-gated) builders; `_KeyGrid` is built once, and the dialpad-tone setting is read per press instead of per build.
- **The answer and decline buttons use the same raw `Listener`, for the same reason** (`incoming_call_screen.dart`, `_CallCircleButton`). A finger on a ringing screen moves a few pixels; a tap recognizer loses that to whatever else is in the arena and the call simply does not answer — the reported "you have to press it several times". `_fired` makes it one-shot, so a press that also drags cannot answer twice.
- **Long-pressing the number readout pastes** (`DialerNumberDisplay._showPasteMenu`). The clipboard is read **before** the menu is built — the `RenderBox`/`Overlay` lookups have to happen before the `await`, and a menu that opens and then discovers there is nothing to paste has to say so somewhere; a snack bar cannot, it renders behind the modal keypad sheet. So the item itself renders disabled as «چیزی برای چسباندن نیست». Pasted text goes through `DialerBloc.sanitizeDialable` (Persian digits folded, everything but `0-9 + * # , ;` dropped).

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
- **A call counts as live only in `CallInCallService.LIVE_STATES`** (SELECT_PHONE_ACCOUNT · CONNECTING · DIALING · RINGING · ACTIVE · HOLDING · PULLING_CALL · SIMULATED_RINGING), and `topLevelCalls()` filters on it as well as on `parent == null`. Telecom adds calls in **STATE_NEW** — Samsung adds two while a conference settles, and one more *after* everyone hung up — and keeps disconnected legs bound for a moment. Counting either as live is what left the call screen up with its timer running after the call had ended: `onCallRemoved` found a "remaining" call that was a corpse and never published DISCONNECTED. A NEW call re-announces itself through `onStateChanged` the instant it becomes real, so nothing is lost by ignoring it. **Four independent teardowns**, because a stuck call screen is unrecoverable without killing the app: `onCallRemoved`, `onStateChanged` (when nothing live is left), `republishCurrent()`, and — in Dart — `CALLS_CHANGED` with `count == 0` plus a `SyncCallState` on every app resume that asks telecom `isInCall` directly. A channel error must never tear a *live* call's UI down, so `_onSyncCallState` returns on failure.
- **A conference host is not a new call.** `onCallAdded` returns early for `PROPERTY_CONFERENCE` — running the outgoing-call branch for it launched MainActivity twice (immediately, then again 2 s later) *on top of a live call*, which is what made «تماس گروهی» stutter.
- **Merge state lives in the details, not in the call state.** Telecom sets the `parent` link *after* `onCallAdded` delivers the conference host, so `onParentChanged` / `onChildrenChanged` / `onDetailsChanged` / `onConferenceableCallsChanged` all have to be registered or «ادغام تماس» stays on screen over an already-merged call. They fire in bursts, so `publishCallsChanged` and `publishState` de-duplicate their payloads — **except DISCONNECTED, which is always sent and clears the memo** (otherwise the same person calling twice in a row is mistaken for a repeat). `republishCurrent()` never publishes for a non-live call: re-announcing a corpse as ACTIVE puts the call screen back over an idle phone.
- **The keypad plays `playKeypadTone`, never `sendDtmf`.** `sendDtmf` pushes the digit into `Call.playDtmfTone` whenever a call exists, and the keypad reached from «افزودن تماس» sits on top of a live one — so typing the number of the person to add played every digit into the ear of the person already on the call. Only the in-call DTMF pad may use `sendDtmf`.
- **The dialer's green pill must NOT be gated on `isInCall`.** That keypad is reached from «افزودن تماس» precisely to place a second call; gating it left the only green button on the screen greyed out with no way to add anyone. In that mode the pill reads «افزودن تماس», the whole suggestion row dials (a contact page is not what anyone is after mid-call) and «ایجاد مخاطب جدید» is dropped.
- **Notifications being off makes every incoming call invisible**, and nothing in the call path can notice. With notifications disabled for the app — or the «تماس ورودی» channel muted — the CallStyle card is dropped *and* its full-screen intent never fires, and because this app holds the dialer role no OEM screen takes over either: the phone rings with nothing on screen and no way to answer. `CallInCallService.ensureChannels` runs from `MainActivity.onCreate` so the channels exist before the first call (otherwise "switched off" is indistinguishable from "never created"), `areCallNotificationsEnabled` reports it, and `DefaultRole.callNotifications` asks for it — **before** `fullScreenIntent`, which is worthless while the card itself is blocked.
- **The screen must blank against the ear — that is the default dialer's own job.** `ProximityGate` holds a `PROXIMITY_SCREEN_OFF_WAKE_LOCK` while a live call is routed to the **earpiece**, refreshed from `onCallAdded` / `onStateChanged` / `onCallAudioStateChanged` / `onCallRemoved` and released in `onDestroy`. It is dropped on speaker, wired headset and bluetooth, where the phone is not at the ear. Equally load-bearing: `FLAG_KEEP_SCREEN_ON` is now set **only while a call is RINGING** (`CallInCallService.hasRingingCall()`), not for the whole call — it holds a screen-bright wake lock, so the call screen stayed lit against the cheek for the entire conversation with «پایان» and «بی‌صدا» exactly where an ear lands. `MainActivity.syncLockScreenVisibility()` is therefore called on every state change, not just on add/remove.
- **Audio output is a route, not a boolean.** `CallAudioState.supportedRouteMask` and the live `route` are published with every AUDIO_STATE event (plus `bluetoothName` on API 28+, best-effort — the app does not hold BLUETOOTH_CONNECT). The picker renders exactly the outputs telecom reports and ticks the live one; `setAudioRoute` is the only way to reach a headset, since `setSpeakerphone` can only flip between the two built-in outputs. Before this, «بلوتوث» was a hardcoded row that answered «دستگاه بلوتوثی یافت نشد» with a headset connected and playing. `SelectAudioRoute` is fire-and-forget: the authoritative route comes back from telecom, so the picker can never show an output telecom refused. A screen that mounted into an ongoing call seeds itself from `getAudioState()` inside `SyncCallState`.
- **«افزودن تماس» is disabled at two calls** — telecom holds at most two top-level calls and a third dial is refused with nothing on screen to explain it. Merging them frees the slot.
- **A rejected call that goes ACTIVE is the carrier, not a bug.** On Irancell, rejecting sends the caller to an operator announcement, so telephony reports `ALERTING -> ACTIVE` and the app correctly shows a connected call. Verified in a telecom trace; do not "fix" it.

**USSD / MMI codes.** `CallHandler.makeCall` sanitizes with **`PhoneNumberUtils.stripSeparators`**, never a hand-rolled character class. A `[^+0-9]` strip is what made USSD impossible: «*100#» reached telecom as «100», so the dialer looked like it *deleted* the `*` and the `#`. The platform rule keeps every dialable character — `*` `#` (USSD/MMI, call forwarding), `,` `;` (post-dial pause/wait for IVR extensions stored in contacts), `N` — and folds Persian/Arabic-Indic digits to ASCII on the way.

- The handle must be built with **`Uri.fromParts("tel", clean, null)`**, which escapes the `#` (`tel:*100%23`) while `getSchemeSpecificPart()` hands telephony back the literal string. `Uri.parse("tel:$clean")` truncates at the `#` — it reads as a fragment. This is the whole of the "ACTION_CALL can't dial USSD" folklore, and it is why the non-default-dialer branch works too.
- **An MMI dial is not a call and must never enter the call UI.** Telephony answers it itself (`com.android.phone` shows the network's reply in its own dialog). AOSP telecom already withholds it from `InCallService`, but `CallInCallService.onCallAdded` drops it too (`isMmiCode`: starts with `*`/`#` **and** ends with `#`, AOSP's own `TelephonyConnectionService` rule) — an OEM that does deliver it would otherwise flash the in-call screen and yank the activity to the front, twice, over the USSD dialog. `onCallRemoved` early-returns for any call not in `trackedCalls`, so neither an MMI nor a rejected blocked caller publishes a `DISCONNECTED` that would repaint a *live* call's screen. Note the trailing `#` in the rule: «#31#0912…» is an MMI prefix on a real call (caller-ID suppression) and keeps the normal UI.
- The dialer hides the suggestion block once `*` or `#` is typed — no contact number carries them, so the only row left was «ایجاد مخاطب جدید» offering to save a USSD code to the address book.

**Speed dial & voicemail — the two things a held key does.** `DialKey`'s long-press already typed its digit (touch-down), so every branch deletes it first.

- **۰ → «+», ۱ → پست صوتی, ۲–۹ → شماره‌گیری سریع.** Speed dial lives in `speed_dial` (DB v21, `position` IS the primary key — one digit, one number) behind `SpeedDialService`, a **synchronously readable** cache loaded once from `DialerBloc`'s constructor: holding a key must dial under the thumb, not wait for a table. The name is denormalized into the row so the manage screen can name the person without reading the address book, and a deleted contact still leaves a working key.
- **Only from an empty field** (`dialedNumber.length != 1` bails). Holding a key in the middle of dialling a number is not a request to call someone else — Google Phone draws the line in the same place.
- An unassigned key **asks** rather than doing nothing (a long-press that silently does nothing reads as a broken keypad), then goes through `showContactPickerSheet`. Settings → «شماره‌گیری سریع» (`SpeedDialScreen`) is where the assignments can be *seen*; ۱ is listed there but never assignable.
- Voicemail is `callVoicemail` (`dialer/services/voicemail.dart`), shared by the held «۱» and the recents overflow menu — this app holds the dialer role, so no stock dialer is left to reach the mailbox from and a gesture inside a modal keypad is not an entry point anyone finds. It asks **which SIM before reading the number** (`getVoicemailNumber(subscriptionId:)`, `TelephonyManager.createForSubscriptionId`): two cards are two carriers with two mailboxes. A carrier that never provisioned one is reported, never guessed at.

**«پاک کردن سابقه تماس» clears the table, not the page.** `ClearCallLogs` → `CallLogService.clearAllCallLogsGlobally` → a native `delete(CallLog.Calls.CONTENT_URI, null, null)` then the local wipe. It used to be `DeleteCallLogs(everything loaded)`, and the list is paginated, so it cleared what was on screen and left the rest to reappear on the next scroll. The local half runs **only** if the provider delete went through (`< 0` = refused), or the next sync brings it all back.

**Role prompts** (`DefaultAppGate`, `lib/core/widgets/default_app_gate.dart`, wraps `MainNavigation` inside `PermissionGate`): a Google-Messages/Phone-style request page, SMS first then dialer. `PermissionGate` NEVER fires a role request itself — the system sheet only opens on the user's tap, which is what makes re-asking safe (Android permanently auto-denies a role after two refusals of the *system* sheet, so the nagging has to live in our own UI).

- It re-checks on every `resumed`, so making another app default elsewhere and coming back asks again; «فعلاً نه» only lasts until the next resume.
- Before the app has been shown once it renders in place; after that it is **pushed as a route** on the root navigator — an inline widget would sit under any conversation/contact page already pushed there.
- On acquiring both roles it dispatches `SyncDeviceMessages` + `SyncCallLogs` + `RefreshContacts` (not `LoadContacts` — the cache predates the role change).
- The inbox banner (SMS) and `openDefaultAppsSettings` remain as the alternate entry points.

### SMS notifications (single native pipeline)

ALL incoming-SMS notifications are posted natively by `SmsNotifier` — from the live dynamic receiver (`SmsHandler`) and the cold-start `IncomingSmsReceiver` alike. `NotificationService` has **no SMS path at all** any more (the one it kept "for a telephony fallback" had no callers and was deleted); never add a Dart-side SMS notification back, it would duplicate the native one.

- Actions are fully native (`SmsNotificationActionReceiver`): inline reply via RemoteInput (sends with SmsManager + provider write-through + app-DB insert) and mark-read (direct DB update). They work with the app dead.
- Notifications are tagged with the threadId; opening a conversation calls `clearThreadNotifications` and `setVisibleThread` over the intents channel — `SmsNotifier` suppresses notifications for the visible thread while the activity is resumed.
- Tap deep-links go through **one** channel: `MainActivity.consumeLaunchAction` returns a typed `{type: thread|dial|sms, …}` → `DeepLinkService.LaunchAction` → `MainNavigation._handleLaunchAction` (cold start: `consumeInitialAction`; warm: `onNewIntent`). Registered post-auth so a tap never bypasses the app lock, and the extra/`intent.data` is stripped as it is consumed so it cannot replay on the next resume.
  - `thread` is the SMS notification's `threadId`. `dial` is another app's `tel:` (ACTION_DIAL/VIEW) → the keypad sheet opens **prefilled** (`showDialerBottomSheet(initialNumber:)`), which is what "call this number I selected in a browser" does in Google Phone. `sms` is `sms:`/`smsto:`/`mms:` or a shared `text/plain` → the conversation with the body already in the composer, or `ContactSelectorScreen(initialText:)` when there is no recipient.
  - An opaque `sms:…?body=` URI **throws** from `getQueryParameter` — the query is parsed by hand and `Uri.decode`d.
- **The conversation resolves the contact name itself** rather than trusting what it was pushed with. Opened from a notification it had only a number, so a saved contact showed as an unknown one *and* got the «گزارش هرزنامه» prompt; it now reads the contact cache synchronously and falls back to an async lookup, and the spam prompt waits for that answer (`_contactResolved`) instead of assuming.
- Blocked numbers are enforced in BOTH receive paths natively (`BlockedNumbers.isBlocked` mirrors `PhoneNormalizer`) and in the Dart listeners; `SmsDeliverReceiver` also skips the provider write, and `CallInCallService` rejects ringing calls from blocked numbers before any UI. Missed calls post a native «تماس بی‌پاسخ» notification (default-dialer duty).
- **One card per conversation, `MessagingStyle`, and it stacks the UNREAD messages only** (`recentMessages`: `type = 'received' AND is_read = 0`, newest `HISTORY_LINES`, read straight from the app's SQLite because this runs with the engine dead). The id is `threadId.hashCode()`; a long-lived shortcut (`setShortcutId` + `setLocusId` + `pushConversationShortcut`) is what moves it into the shade's conversation section and makes the **expand chevron** work — before this it was one notification per *message*, each with a single line and nothing to expand to. It briefly replayed the last five rows of any type, which showed the user their own replies and messages they had already read; a notification is the list of what has not been seen.
- **The carrier's own missed-call SMS is not a second notification.** Iranian operators text «تعداد ۱ تماس از 0912… داشته‌اید» from an alphanumeric sender for a call this app — the default dialer *and* the default SMS app — already posted «تماس بی‌پاسخ» for. That is the reported "one missed call, two notifications, and the one labelled «تماس» can't call back" (tapping the SMS opens a chat with `MissedCalls`). `CallInCallService.markMissedCall` stamps the number into SharedPreferences (30-min TTL, survives process death because the SMS often lands after the app is gone) and `SmsNotifier.isRedundantMissedCallSms` drops **only the notification** when all three hold: a non-dialable sender, a body naming a number marked missed, and wording that is about a call. The message is still delivered and still in the inbox. Do not weaken the marked-number condition to a body-pattern guess — the cost of a false positive is a silently swallowed notification.

### Group send («پیام گروهی»)

**One message, several recipients, sent as one SMS each — and the screen says so.** This app does not do MMS, and a group *conversation* is an MMS construct: without it there is no thread the replies could come back into. Google Messages with «Group MMS» off behaves exactly this way, so `BroadcastComposeScreen` is the honest version rather than a group thread that could never receive anything.

- Two entry points, one screen: the «پیام گروهی» row in `ContactSelectorScreen` (rows become a multi-select) and «پیامک گروهی» on a label page.
- **Everything above the contact list is a tax on the list.** The first pass spent an 80 dp filled card plus a full-width button on the mode, which pushed the first contact off the screen as soon as one chip was picked. Now: a 56 dp row to turn it on, a compact header + chips once it is, and the CTA in `bottomNavigationBar`. The chips' `Wrap` needs an explicit full width — the parent `Column` centres a shrink-wrapped one and the chips float in the middle of an RTL screen.
- The counter under the send button multiplies **parts × recipients**, because that is what a group send actually costs; the per-message segment maths is the chat composer's (`70`/`67` Unicode, `160`/`153` GSM-7).
- Recipients are deduplicated on `PhoneNormalizer.toThreadId`, so «+98912…» and «0912…» are one person. Each send is an ordinary `SendMessage`, so every message lands in its own conversation with its own delivery report.

### Composer attachments («+» sheet)

Every row does something. «دوربین» / «گالری» / «صدا» were **removed**, not left as
"coming soon": MMS is deliberately unsupported, so there is nothing for them to
ever do, and three dead entries are worse than a shorter menu.

- **«موقعیت» inserts text, not an attachment** — `LocationService.currentLocation()`
  → «35.762397, 51.403567» appended to the composer. **ASCII digits and a leading
  LRM on purpose**: the receiver pastes this into a map, so Persian digits would
  be useless, and the mark keeps the pair in order inside an RTL sentence. Six
  decimals ≈ 10 cm; past that the digits are noise.
- **Platform `LocationManager`, no plugin** (`LocationHandler.kt`): one coordinate
  pair on one tap is not a location library, and every plugin here drags in the
  Kotlin Gradle Plugin the build already warns about. `getCurrentLocation`
  (API 30+) is the only call that will turn the radio on; `getLastKnownLocation`
  is the fallback and is trusted only while it is under two minutes old — an
  hour-old fix from another city is worse than admitting there is none. The
  result is answered **at most once** (`replied` guard): a fresh fix landing
  after the fallback already replied would crash on a second `Result` call.
- Each failure has its own Persian sentence (`LocationService.messageFor`) —
  permission refused, refused permanently, location services off, no fix — because
  «نشد» leaves the user with nothing to do. Nothing is stored or tracked; the
  coordinates leave the device only inside the SMS the user chooses to send.

### Composer growth

The composer's field grows with the message and then scrolls inside itself,
measured against Google Messages on a real device: it stops at ~10 lines
(~320 dp), keeps the «+» / emoji buttons pinned to the bottom line, and never
changes its 28 dp corner radius.

`MessageComposer._maxLinesFor` derives `maxLines` from the space actually left
on screen (`size.height − padding.top − max(keyboard inset, emoji-panel height)
− _kReservedForChat`), clamped to `_kMaxLines`. The cap must stay a **height**,
not a plain `maxLines: 10`: with the emoji panel open a ten-line field plus the
panel is taller than the screen and the composer's `Column` overflows.

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

### One-time codes («کپی ۱۲۳۴۵»)

`OneTimeCode.find` (`messages/models/one_time_code.dart`) puts a copy chip under a **received** bubble carrying a verification code — the one thing anyone does with such a message, against a long-press → lift → word-select → toolbar tap on digits that expire in two minutes.

Two gates keep it off every number in the inbox, and both are load-bearing:

- The message has to **say** it is carrying a code (folded keyword list: رمز/کد/پویا/تایید/otp/…), and the run nearest that word wins.
- The digits have to **stand alone**: 4–8 long, not a slice of a bigger number (a separator with digits on the far side — a date, a time, a thousands separator; a bare full stop is a sentence, not a decimal), not followed by a unit (تومان/ریال/درصد/روز…), and not suspiciously round (≥3 trailing zeros). That last pair is what stopped «کد تخفیف ۳۰۰۰۰۰ تومانی» from offering to copy the *price* — the wrong number under the right label.
- The code is copied as **ASCII** whatever the message used (it is pasted into another app's field) while the chip shows Persian digits.
- **Alphanumeric codes are deliberately out of scope**: OTPs here are numeric, and matching uppercase tokens would fire on every English promo.

### Delivery status (bubble ticks)

`SmsService.sendSms` generates the message UUID BEFORE the native send and passes it as `trackingId`; the native sent/delivered PendingIntents carry it back through the SMS EventChannel as typed `{"type":"status"}` events (incoming SMS events carry `"type":"received"`). `SmsService` updates the DB row and broadcasts on the static `onMessageStatusChanged`; `MessageBloc.MessageStatusChanged` swaps the message in the open conversation in place (⏱ pending → ✓ sent → ✓✓ delivered / failed with retry).

**Tapping a bubble expands it** (`ConversationScreen._expandedMessageId` → `MessageBubble.expanded`): the time appears, and on a sent one the tick gets its word («در حال ارسال» / «ارسال شد» / «تحویل داده شد» / «ارسال نشد»). Tapping it again collapses it, and only one bubble is expanded at a time. The tick alone is not readable — «✓ vs ✓✓» is a convention this app never taught anyone — and the alternative was the long-press overflow's «اطلاعات», which is three gestures to answer "did it arrive". Long-press still opens the action overlay; the tap is ignored while a selection is running.

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

### Dual SIM

`lib/core/sim/` (model · service · bloc · widgets) over `android/.../sim/SimRegistry.kt` + `SimHandler.kt`. Google Messages' and Google Phone's behaviour, followed exactly:

- **One SIM ⇒ nothing changes.** Every affordance — the composer chip, the pickers, the bubble/call-log badges, the notification subtext, the «ذخیره در» row — hangs off `SimService.isMultiSim`. A single-SIM phone must look byte-identical to the app before this existed.
- **The identity that travels is the `subscriptionId`; the *slot* is only ever displayed.** A subscription id is an opaque per-device counter that changes when a card is re-inserted, so a stored preference names the subscription while «سیم ۱» names the tray.
- **NULL means unknown, never SIM 1.** `messages.subscription_id`, `call_logs.subscription_id` and `CallInfo.subscriptionId` are null for every row that predates this, for provider rows the OEM never stamped, and for VoIP calls. A wrong SIM badge is worse than none, so the UI omits it.
- **`SimRegistry` is an `object`, not a handler**, because `SmsNotifier`, `IncomingSmsReceiver` and `ScheduledSmsWorker` need SIM answers *while the Flutter engine is dead*. Every read is wrapped: `SubscriptionManager` throws until READ_PHONE_STATE is granted and the app must degrade to "single, unknown SIM" rather than drop an SMS.
- **Telecom names a `PhoneAccountHandle`, not a subscription, and no public API maps the two.** `SimRegistry.phoneAccountFor` / `subscriptionIdForAccountId` match on `handle.id == subId` (modern AOSP — verified on the SM A336E: id `"10"`), then the ICC ID, then the account label, then slot order. The same mapping serves outgoing calls (`EXTRA_PHONE_ACCOUNT_HANDLE`) and the call log's `PHONE_ACCOUNT_ID`; Dart caches it in `SimService.subscriptionForAccountId`.
- **`CallLogService` must `await SimService.instance.ensureLoaded()` before mapping rows.** The mapping's result is *persisted*, so running before the roster exists stamps "no SIM" on every call permanently. `SimBloc` loads at startup but the call-log sync wins that race on a cold start.
- `call_logs.sim_slot` is dead: it stored `simDisplayName != null ? 1 : null`, i.e. **every** call on either card claimed «سیم ۱». The column is left in place (rebuilding a table for a value nothing believes is not worth it) and `subscription_id` (DB v20) replaces it.
- **SMS remembers the SIM per conversation** (`thread_sim`, `ThreadSimRepository`), written *on the send* rather than on the pick, so it reflects what actually went out. A global "selected SIM" would be wrong for every conversation but the last. The notification quick-reply answers on the SIM the message arrived on.
- **The picker only appears when there is a real choice**: two SIMs *and* no system default pinned (`SimService.defaultFor`). Second-guessing the user's Android setting is the bug, not the feature. `placeCall` (`core/sim/sim_call.dart`) is the ONE dial path in the app for exactly this reason — do not call `NativeCallService.makeCall` directly.
- **…but there is ALWAYS an explicit override**, or a pinned default makes the other card unreachable from the app — which is exactly what the first pass got wrong. Three affordances, all through `placeCallPickingSim`: the keypad's SIM chip beside the call pill (a *setting*, kept in `DialerState.dialSubscriptionId` because the keypad lives in a sheet that gets torn down), a **long-press on every call button** in the app, and the explicit «تماس با سیم …» rows `simCallRows` adds to the call-log / favourites / number sheets.
- **The send pre-flight is per-SIM.** `SmsHandler.isInService(subscriptionId)` builds a `TelephonyManager.createForSubscriptionId`; reading the *default* subscription's `ServiceState` made the two cards lie about each other — a send on SIM 2 refused with NO_SERVICE because SIM 1 had no signal, and a send on a card that genuinely had none sailing past the check into the radio queue (which reads to the user as "it sent, very late").
- **`SimRegistry.subscriptions` is cached** (30 s TTL, dropped by `OnSubscriptionsChangedListener`). It is several binder round-trips — plus one per SIM for the card's own number on API 33+ — and it sits on the incoming-SMS notification path (twice) and on every telecom call-state change. `withNumbers` is opt-in and uncached: only the Dart picker displays numbers.
- **Never rebuild a `MessageModel` field by field — use `copyWith`.** `MessageBloc._onMessageStatusChanged` and `_mergePersistedMessage` did, and each silently dropped whatever field was added last: a bubble lost its SIM badge the instant its ✓✓ landed and only got it back on the next read from the DB.
- **Scheduled messages carry `subscription_id`** and `ScheduledSmsWorker` (Kotlin) resolves null to the system default before sending, so the send, the provider row and the chat row all name the same card. Change it with `scheduled_message_model.dart`, as ever.

**SIM contacts are NOT in `ContactsContract`.** The provider only carries them once the device's *default* contacts app has registered a SIM account and imported the card — which does not happen on a phone where this app is the contacts surface, so `flutter_contacts` returns the same list with a second SIM inserted as without one. `SimContactsHandler.kt` reads `content://icc/adn/subId/<subId>` per active subscription (the bare `content://icc/adn` always resolves to the *default* subscription, so a naive version shows SIM 1's contacts twice), and `ContactRepository._mergeSimContacts` appends them, dropping any whose number the phone book already has. They are `ContactSource.sim`: no photo, no editing in place (an ADN record is one name, one number, a card-set length limit and no durable id), so «ویرایش» becomes «کپی در تلفن» and deletes go through the ICC provider by content match. `ContactBloc` re-reads on every roster change — that is the other half of "the new SIM's contacts never appeared".

### Authentication & app lock

- Auth type (PIN or pattern) is stored in `flutter_secure_storage`; the credential itself is stored **salted and stretched** (`v2:<salt>:<hash>`, 60 k rounds of SHA-256), not in plaintext. Rows written by older versions are plaintext and are upgraded in place on the first *successful* validation — never on a wrong guess.
- **A forgotten PIN is no longer a permanent lockout.** Setting a PIN mints a one-time recovery code (`AuthRepository.regenerateRecoveryCode`, hash-only storage, unambiguous alphabet with no O/0 or I/1) which `PinSetupScreen` shows once via `RecoveryCodeScreen`. `AuthBloc` emits `AuthRecoveryCodeIssued` **before** `AuthAuthenticated` for that reason — reorder them and the code is minted and lost in the same frame. «رمز را فراموش کرده‌ام» on both lock screens verifies it and drops to the set-a-PIN flow; it never unlocks the app directly, because a code written on paper must not become a second password. Settings → «کد بازیابی جدید» re-mints it from inside an unlocked app.
- `AppLockService` tracks the locked/unlocked state in memory.
- `AppLockWrapper` listens for `AppLifecycleState` changes and can re-lock the app on resume.

### Crash reporting

`CrashReporting` (`core/services/`) wraps `main`. Off unless a DSN was compiled in (`--dart-define=SENTRY_DSN=…`) **and** the user opted in (Settings → «تشخیص خطا», default off, takes effect next launch).

- It uses the **pure-Dart `sentry`**, not `sentry_flutter`: that package ships its own Android Gradle plugin pinned to AGP 7.4.2, which this project's build cannot resolve — `assembleDebug` fails outright. The cost is that Kotlin-side crashes are not reported; `FlutterError.onError` and `PlatformDispatcher.onError` are hooked by hand for the Dart half.
- **Nothing about a message leaves the device**: `sendDefaultPii` off, no screenshots or view hierarchy, `console`/`http`/`query` breadcrumbs dropped whole (`debugPrint` in this app legitimately prints bodies), breadcrumb `data` blanked, and every remaining string run through a redactor that replaces any run of ≥ 4 digits. Do not relax any of these — this is the default SMS app.

### RTL / Persian

All UI text is Persian. Wrap any new screen or dialog root with `Directionality(textDirection: TextDirection.rtl, ...)` or use `RtlAppBar`. The `PersianUtils` class and `AppConstants.persianNumbers` handle Persian digit conversion.
