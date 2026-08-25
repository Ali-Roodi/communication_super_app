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

Single SQLite database (`communication_app.db`, version 23) managed by `DatabaseHelper` singleton (`lib/core/database/`). Tables: `contacts`, `messages`, `call_logs`, `favorites`, `blocked_numbers`, `archived_threads`, `pinned_threads`, `message_categories`, `drafts`, `message_templates`, `scheduled_messages`, `thread_sim`, `speed_dial`, `message_groups`, `message_group_members`, `message_group_targets`, `contact_name_cache`. Constants in `AppConstants`.

**Schema invariants:**
- `contact_name_cache` (DB v23, `ContactNameCache`) is the address book as `ContactRepository.getDeviceContacts` last read it — normalized number → name + contact id — and it is a **cache, never a source of truth**. It exists because the address book is on the far side of a platform channel: both the inbox and «اخیر» paint from SQLite immediately and used to do it as bare *numbers*, dropping the names in as a second emit a beat later, on every single launch. Now the first emit is named from this table and the authoritative read still runs behind it; when nothing has changed the second emit is `==` to the first and `ThreadsLoaded` / `CallLogsLoaded` being Equatable means nothing repaints. Two rules keep it honest: only a completed device read writes it (so it cannot drift), and the write **replaces the whole set** in one transaction rather than upserting — an upsert-only cache would go on naming a contact the user deleted.
- `messages.thread_id` is the digits-only normalized phone number — **except** for a group conversation, where it is `'g:' || message_groups.id` (`GroupThread`). That is why every inbox/search/pin/archive query works on a group without a branch, and why nothing may pass a thread id to a *display* helper without checking `isGroup` first.
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

**The time picker is `dialOnly`.** Its keyboard-entry mode is broken in Persian and cannot be fixed from the call site: `GlobalMaterialLocalizations` for `fa` fills the field with Persian digits and Flutter's own validator parses it with `int.tryParse`, which does not read «۱۹» — so the dialog opened on its own value and answered «زمان معتبری وارد کنید» before anything was typed (verified on the device, unedited). The alternative — a `MaterialLocalizations` override emitting ASCII — fixes the parse by putting «16:19» on a dial the rest of the app renders in Persian, so the toggle is simply not offered. Same for `TemplateFillScreen`'s time field.

**`ScheduledMessageBloc` is provided with `lazy: false`, and that is not a detail.** A `BlocProvider` is lazy by default and this bloc is read *only* from `ConversationScreen` and `ScheduledMessagesScreen`, so on an ordinary launch it was never constructed: no 30-second tick, no `LoadScheduled`, and therefore **the native alarm was never re-armed for what was already pending**. A message scheduled for 09:00 whose alarm the OS had dropped sat there through every launch until the user happened to open a conversation — at which point the first sweep found it overdue and sent it that minute. That is the whole of «زمان‌بندی درست کار نمی‌کند»: scheduled 09:00, delivered 11:00, the instant the app was opened. `MainNavigation` also re-arms on every `resumed`, because an alarm is not durable state — Doze, App Standby and every OEM battery sweep can drop it while the process is dead, and each return to the app is a chance to put it back.

Two deliverers exist:
- **Dart** — `ScheduledMessageBloc` ticks every 30 s and calls `ScheduledDeliveryService.deliverDue()`.
- **Native** — `ScheduledSmsWorker.processDue()` runs from an AlarmManager broadcast when the app is dead.

When the alarm fires and the Flutter engine is alive, `ScheduledSmsAlarmReceiver` hands the delivery *back to Dart* over `ScheduledSmsChannel` (`deliverDue`) instead of sending natively. This is load-bearing: the native worker writes straight to SQLite, so a native send while the app is running leaves `ScheduledMessageBloc` and `MessageBloc` stale — the chat keeps its scheduled ghost bubble and never shows the sent message. `MainActivity` publishes the channel in `configureFlutterEngine` and clears it in `onDestroy`.

Still, they coordinate through `ScheduledMessageRepository.claimDue(now, token)`: one atomic `UPDATE … SET status='sending', claim_token=?` stamps the due rows, and each deliverer only processes rows carrying its own token. **Never send a scheduled message without claiming it first.** A row stuck in `sending` past `ScheduledMessage.staleClaimTimeout` is released back to `pending`.

**Jitter is enforced, not decorative, and all three parties compute the SAME offset.** `ScheduledMessage.jitterOffset` derives a *deterministic* offset inside the window from (id, scheduledAt, occurrenceCount) — a re-rolled offset would let a row fire early on the next tick — and `isDueAt` compares against `effectiveSendAt`. The window can't be expressed in SQL, so `ScheduledDeliveryService` reads `getDue`, filters, and passes the surviving ids to `claimDue(…, restrictTo:)`. `ScheduledSmsWorker.claimDue` (Kotlin) applies the same gate and hands rows whose window hasn't opened back to `pending`. «ارسال فوری» must bypass all of this: `SendScheduledNow` calls `deliverDue(force: {id})`.

- The seed is **`ScheduledMessage.jitterSeed`, a plain 32-bit FNV-1a over the id's UTF-16 units, the scheduled instant and the occurrence** — pinned by reference vectors in `test/unit/scheduled_message_test.dart` and mirrored character for character in `ScheduledSmsWorker.jitterSeed`. `Object.hash` and `String.hashCode` are implementation-defined and differ between Dart and Kotlin, so neither may be used here.
- They used to disagree three ways: Dart hashed with `Object.hash`, Kotlin with `id.hashCode()`, and **`ScheduledSmsScheduler` rolled a fresh `Random` for the alarm**. So the alarm woke the phone at one point in the window, whichever deliverer ran decided the window had not opened, handed the row back to `pending`, and the message waited for a later wake-up — a jittered message could land long after the window it was promised. `ScheduledSmsWorker.earliestPending` now returns the *effective* instant (jitter baked in, never before a pending `next_attempt_at`) and the scheduler arms exactly that.

**The alarm is a `setAlarmClock` when the send is within 24 h, `setExactAndAllowWhileIdle` beyond it.** `setExactAndAllowWhileIdle` escapes Doze but **not App Standby** — an app the phone has decided is "rare" (every app the user has not opened today, and on some OEM builds every app they have not opened this hour) has its exact alarms throttled to one every few hours, which for a message promised at 09:00 is a broken feature. An alarm clock is the only alarm the platform will not defer; verified on the device with `dumpsys alarm`, which lists it as the phone's **`Next wake from idle`**. The cost is the system's next-alarm icon, which is why a schedule still days out does not get one. Its `AlarmClockInfo` show-intent is the app launcher, never the delivery broadcast — reusing that would send the message when the user tapped the icon.

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

**Reading the rows is native too** (`callLogEntries` → `CallLogSyncHandler.queryEntries`), and that is a crash fix, not a tidy-up. It was the `call_log` package, which **requests READ_CALL_LOG itself** (`ActivityCompat.requestPermissions(..., 0)`), parks the one pending `MethodChannel.Result` in a field, and — when a second call arrives while its dialog is up — replies on that result twice: `IllegalStateException: Reply already submitted`, thrown on the main looper out of `onRequestPermissionsResult`, i.e. an uncatchable crash. It fires on a **fresh install only**, because from the second run the permission is already granted and the plugin never opens a dialog; that is exactly the "crashes after the first install" report, reproduced on a Redmi Note 7 (Android 10) on 2026-08-17. `another_telephony` was removed earlier for the identical defect, and `flutter_phone_direct_caller` (unused) with it.

**So: no plugin in this app may request a runtime permission.** Every grant goes through `PermissionGate`, and a plugin that opens its own dialog both double-asks and — since these plugins keep exactly one `Result` — dies the moment two calls overlap. The native handlers never ask: a missing grant surfaces as a `SecurityException` mapped to `PERMISSION_DENIED`, which the Dart side treats as "cannot read" (keep the mirror) rather than "nothing there" (wipe it). Row mapping (`CallLog.Calls.TYPE` → `CallType`) is deliberately done in **Dart**, so a constant this build has never heard of still arrives intact.

**Contact extras / «برنامه‌های متصل»:** `ContactExtrasHandler.kt` reads the third-party Data rows on a contact (rows whose MIME type is outside the standard set). Two things this depends on, both easy to break: the manifest `<queries>` entries for `android.accounts.AccountAuthenticator` and `VIEW`+`vnd.android.cursor.item/*` (targetSdk 30+ package visibility otherwise hides the authenticator, `packageForAccountType` returns null and the whole section renders empty), and resolving the row's action to a **concrete component** before launching — messengers register several activity-aliases per custom MIME type, so an implicit intent (even with `setPackage`) pops an "Open with" sheet listing the same app twice.

**Merging duplicates is `AggregationExceptions`, not a rewrite.** `ContactLinkHandler.kt` (+ `ContactLinkService`) writes `TYPE_KEEP_TOGETHER` over every pair of the raw contacts behind the selected contacts — `flutter_contacts` cannot do this, and "write one contact and delete the others" is a different, lossy thing: nothing is copied, nothing is deleted, each account keeps its own row, and `unlink` (`TYPE_KEEP_SEPARATE`, so the provider's matcher cannot silently re-aggregate) takes it apart again. The row is written with `newUpdate` — the provider upserts on the (raw1, raw2) key and an insert throws.

- Three entry points: the contacts selection bar («ادغام», hidden when the selection includes a SIM contact — an ADN record has no ContactsContract row to aggregate), `DuplicateContactsScreen` (union-find over *shared number* **or** *same folded name*; both rules are needed, and grouping has to be transitive), and «جدا کردن مخاطب‌های پیوندشده» on the contact page, shown only when `rawContactCount > 1`.
- The linked id is **not** necessarily one of the inputs — the provider re-aggregates and picks — so callers refresh instead of assuming.
- **The merge asks whose name and photo survive** (`showMergeContactsDialog` → `link(ids, primaryContactId:)`). Aggregation alone does not decide that: the provider picks a display name of its own, so merging «علی» with a row saved as a number silently renamed the person. `ContactLinkHandler` captures the chosen contact's raw ids *before* aggregating and then sets `IS_SUPER_PRIMARY`/`IS_PRIMARY` on its StructuredName and Photo rows. Both entry points (selection bar, `DuplicateContactsScreen`) go through the dialog; it defaults to the longest name.

**Labels («برچسب‌ها») are editable, and the provider's group list is not the user's.** Every account carries its own «Family»/«Coworkers», and a Google contact also sits in «My Contacts» and «Starred in Android». `ContactGroupsService` therefore exposes a `ContactLabel` = *name* + every group id carrying it: one row on screen, reads and writes fanned out, internal names hidden (`isInternal` / `visibleNames`). Without that the labels screen listed «Coworkers» three times.

**Memberships are written natively, NOT through `flutter_contacts`** (`ContactGroupsHandler.kt`, channel `…/contact_groups`). A `Groups` row and a `RawContacts` row each belong to an account and a `GroupMembership` is only valid when **the two match**; the plugin's `insertGroup` writes a TITLE and no account at all, so every label made through it was account-less, every membership written against it meaningless, and the label came back empty — which is the whole of the "I save a contact into a label and the label is empty" report. `applyLabels` / `addToLabel` / `removeFromLabel` / `memberIds` / `createLabel` replace it; `AddEditContactScreen` saves the contact with a plain `update()`/`insert()` and then calls `applyLabels`.

- **`AddEditContactScreen._save` must clear `contact.groups` before writing, and that is a crash fix.** `flutter_contacts` builds one `GroupMembership` INSERT per entry of `contact.groups` on *every* update — unconditionally — while deleting the existing membership rows only when `withGroups: true`, which this call is not. So each save **doubled** the contact's membership rows (1 → 2 → 4 …), and around the tenth save the batch crossed `ContactsProvider2`'s ceiling of 500 operations: `applyBatch` threw «Too many content provider operations between yield points», the plugin runs it on a bare `CoroutineScope(Dispatchers.IO)` with **no try/catch**, and an uncaught exception on a background thread kills the process. That is the whole of «I update a contact photo, press save, and the app throws me out» — nothing Dart could catch, and the photo was never the cause. Verified on the device: one contact had reached 512 identical rows for one group.
- **Any batch this app hands the contacts provider is chunked below 500** — `ContactGroupsHandler.applyInChunks` and the bulk contact delete in `ContactsListScreen`. A batch that crosses the ceiling writes nothing at all, and through the plugin it takes the process with it.
- `applyLabels` **drops duplicate membership rows** (same raw contact, same group) as it goes: it is the only repair path for contacts the earlier builds already multiplied.

- **The account a new label goes into is ranked, not just "the busiest"** (`busiestAccount` + `accountRank`). A messenger that mirrors the whole address book into its own sync account outnumbers the phone's real store — measured on the test device, 298 rows in `ir.eitaa.messenger` against 158 in `vnd.sec.contact.phone` — so plain "busiest" created every label inside a **read-only copy** its adapter may wipe. Rank comes from `ContentResolver.getSyncAdapterTypes()` (no permission needed): no contacts adapter registered = a device-local store and the best home (2), an adapter that `supportsUploading` = a real cloud account (1), a download-only adapter = a mirror (0). SIM accounts are excluded — an ADN record has no `Groups` row to belong to.
- **A label lives in as many accounts as it has members.** `applyLabels` writes each membership against a raw contact **in the group's own account**, creating the group in that account when it is not there yet, and `memberIds` matches by *title* across accounts. So one «Family» on screen is routinely several `Groups` rows underneath, and that is correct.
- `groupFor` prefers an id the contact already carries, so saving does not move the tag to another account.
- The «برچسب‌ها» row sits in the editor's main form, **not** behind «فیلدهای بیشتر» — buried there nobody found it, which is most of why labels went unused.
- A label page («برچسب‌ها» → tap) is where a label is *used*: «افزودن مخاطب» (contact picker → `addToLabel`) and «پیامک گروهی» (→ the group conversation for its members, named after the label) live in its app bar, and deleting a label asks first — the membership rows go with it and re-creating the name brings nobody back.

### Contact photo («عکس مخاطب»)

Tapping the avatar in the editor opens Google Contacts' three-row sheet — «گرفتن عکس» / «انتخاب از گالری» / «حذف عکس» (the last only when there is one) — and a pick goes through `PhotoCropScreen`: drag to move, pinch to zoom, «چرخش» a quarter turn at a time, inside a circular window. The whole avatar is the button with one badge on it; it used to be two floating buttons stuck to the circle, one of them a delete, which put "throw the photo away" a mis-tap from "change the photo".

- **The UI is Dart, the pixels are Kotlin** (`media/PhotoHandler.kt`). The crop screen never touches image data: it sends the rotation and a *normalised* rectangle, and the native side rotates, cuts and re-encodes. Stateless — `pick` hands preview bytes (1536 px) to Dart and forgets them, `crop` takes them back — so nothing has to survive the camera activity being stopped behind us.
- **Platform intents, no plugin.** `image_picker` + `image_cropper` bring the Kotlin Gradle Plugin this build already warns about, and a plugin that requests its own runtime permission is banned here (see the `call_log` crashes). `android.permission.CAMERA` is deliberately **not** declared — declaring it would make the platform *require* a grant the app never needs.
- **`REQUEST_GALLERY`/`REQUEST_CAMERA` are 92xx, and that block is load-bearing.** The camera was 9002, which is `SmsHandler.REQUEST_DEFAULT_SMS_ROLE`; `MainActivity.onActivityResult` offers the result to the role handlers first, that one claimed it and returned, and the capture arrived nowhere — the sheet closed and the photo never changed. Roles own 90xx, contact extras 91xx, photos 92xx.
- **`resultCode` is not trusted on the camera path.** Several OEM camera apps answer an `EXTRA_OUTPUT` capture with a null data Intent (and sometimes RESULT_CANCELED) after writing the file perfectly well. The file the camera was told to write — a fixed path under `cache/contact_photos`, deleted before each capture — is the source of truth; empty file + RESULT_OK is reported as a real error rather than silence.
- **EXIF orientation is applied on decode.** Almost every camera stores a portrait shot as a landscape frame plus a tag; the previous version ignored it, so a camera photo came out on its side.
- **«حذف عکس» is a native delete.** `flutter_contacts` ignores `contact.photo = null` on update — the row stays and the old picture is back on the next read. `deleteContactPhoto` removes the Photo data row from every raw contact behind the aggregate, and runs **after** `update()`, which would otherwise write it straight back.
- The crop opens **centred**, not at the top-left corner: a portrait photo is taller than the window and cornering it framed every one of them on the forehead.

**The phone field in the editor is LTR** (`Directionality.ltr` around the `TextFormField`, alone on this form). A phone number is left-to-right content: in the page's RTL direction the digits laid out right-aligned with the caret on the wrong side, so typing read as if the number were going in backwards and a leading `+` landed at the far end. The *detail* page's `_phoneTile` is deliberately left as it is — it renders LTR text right-aligned inside the RTL row and that is correct there.

**Contacts:** all writes go straight to the device address book via `flutter_contacts` (`AddEditContactScreen`); there are deliberately NO create/update/delete bloc events. `ContactRepository.getContactByPhoneNumber` resolves against the device-contact cache (normalized-number match) — the local `contacts` table is legacy and nothing writes to it.

**A rename reaches every surface, because there is one signal.** `ContactRepository.revision` is a `ValueNotifier` bumped by `invalidateCache()` — i.e. by every mutation, ours or the phone's Contacts app (`MainNavigation._refreshDeviceContacts` invalidates rather than dispatching, so both sources arrive the same way). `MainNavigation` listens and fans out `RefreshContacts` + `RefreshContactNames` + `RefreshCallLogContactNames`; the conversation header re-resolves its own title (`_resolveContactName(force: true)`, which must also be able to go back to *no* name — the contact may have been deleted, and the spam prompt hangs off that answer); the details page and each `_FavoriteCard` re-read their own contact. Before this, renaming from the chat header updated the contacts tab and nothing else: the header behind it, «اخیر» and «مورد علاقه» all kept the old name until the app was restarted.

- It is bumped by `invalidateCache()` and **not** by a `forceRefresh` read — that read is how the listeners themselves reload, so bumping there would loop.
- **Starring is per *person*, not per number.** The picker used to ask «کدام شماره؟» for a contact with several; that made adding a favourite a two-step decision about a question that only matters at the moment of *calling* — and it is asked there, by the long-press sheet and by `placeCall`. The row is keyed on the contact's primary number and `_FavoriteCard` resolves the live contact from it, so the name, the photo and the numbers all stay current.
- **«مورد علاقه» stores a denormalized name** (`favorites.name`, the name the number had when it was starred), so it can never be corrected by a bloc refresh. `_FavoriteCard` resolves the live contact and prefers it, keeping the stored copy only as the fallback for a number that belongs to no contact.
- **`call_logs` has no contact-name column at all** — it is overlaid per page by `CallLogService.resolveContactNames` — so `RefreshCallLogContactNames` re-reads the paged-in rows rather than patching them: a name has to be able to *disappear* when its contact is deleted, and an overlay can only add.

The static contact cache carries a **generation counter**: `invalidateCache()` / `forceRefresh` bump it, and a read that started before the bump refuses to publish its (pre-write) snapshot. Saving a contact invalidates the cache while the `FlutterContacts.addListener` refresh already has a read in flight — without the guard that stale snapshot won, and a contact added from a call log stayed missing from the list *and* the search until the next app start.

**An edit is visible on the page you edited from.** Two halves, and both were missing: `DeviceContactDetailScreen` derives its title from the contact it *re-read* after the editor pops (through `ContactNameStyle.format`, so it obeys «قالب نام»), and `LazyContactAvatar` carries a `static ValueNotifier<int> generation` bumped inside `invalidateCache()` — every mounted avatar listens and reloads its own bytes. Without the second one the name updated and the photo did not, which looks worse than neither. Before this, a rename or a new photo only appeared after leaving the contacts screen and coming back.

### «اخیر» — tap shows actions, long-press shows history

`CallLogTile` expands **in place** on a tap (Google Phone's accordion, so the list never loses its scroll position) and the expansion is now *only* the tonal action rows. It used to list the timestamps of the other calls merged into the row above them, which pushed the buttons the tap was for down the card to make room for something nobody had asked for. The per-call breakdown — with the SMS exchanged with the same number merged into one newest-first timeline — lives in `showCallDetailSheet`, reached by **long-pressing** the row or by «سابقه» inside the expansion.

**Keeping a number and reaching the person behind one are different questions, and both are answered.** `save_number_actions.dart` holds the pair, shared by the recents row, the call-detail sheet, the conversation's overflow and the tapped-number sheet:

- «ایجاد مخاطب جدید» → `AddEditContactScreen(initialPhone:)`.
- **«افزودن به مخاطب موجود»** → contact picker → the *editor* for that person with the number appended. This was missing everywhere and is the more common case by far (a second number for somebody already in the book); without it the only way to record one was to leave for Contacts and find the person by hand. The editor is opened rather than the number written silently because the label (همراه/خانه/محل کار) is a real question — and because a wrong pick has to be noticeable. `AddEditContactScreen` skips the append when the contact already has the number in any equivalent form (`PhoneNormalizer.toThreadId`), so picking the person it already belongs to does not add a duplicate row.
- The picker is opened with `pickNumber: false` (pick the *person*, one step, and list people with no number at all — the whole point is that they do not have this one) and `editableOnly: true` (a SIM/ADN record has no ContactsContract row to edit, so offering one leads to an editor that cannot open).

A recents row that **did** resolve to somebody gets «مشاهده مخاطب» + «ویرایش مخاطب». Editing had no entry point from «اخیر» at all: fixing a name for a person you had just spoken to meant leaving for the contacts tab and finding them again.

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

### The keypad's number actions

`DialerNumberActions` sits under «پیشنهادی» for **every** number typed and whether or not a contact matched: «ایجاد مخاطب جدید» (spelling the number out) · «افزودن به مخاطب موجود» · «ارسال پیامک». Google Phone lists all three from the first digit. This app showed only the first, and only while *nothing* matched — so a second number for somebody already saved, and texting a number you had just typed, were both unreachable from the keypad. Dropped only in «افزودن تماس» mode, where the keypad is picking the second leg of a conference and nothing else. The first two go through `save_number_actions.dart`, the same pair «اخیر» and the tapped-number sheet use.

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
- **`showOverLockScreen(false)` may only hand the screen back if a call put us there.** It runs from `onCreate`/`onResume` too, so the unguarded `moveTaskToBack(true)` fired whenever the activity was created or resumed with the keyguard still up — the app threw itself to the background and the user came back to the home screen with whatever they had been reading gone. That is «هر بار بعد از لاک کردن گوشی اپ بسته میشه».
  **Repro:** `input keyevent 26` (screen off), then `am start` the activity while
  the keyguard is up — pre-fix the resumed activity afterwards is the *launcher*,
  with the gate it is MainActivity, waiting behind the keyguard as it should.
  Screen-on and unlock alone do **not** reproduce on every phone (the SM A336E
  does not resume behind its keyguard), but `onCreate` reaches the same call
  everywhere, so any launch onto a locked screen — a notification tap — hit it. `MainActivity.overLockScreen` gates it: only clearing a flag a live call actually set may move the task back. (`android:taskAffinity=""` was dropped from the manifest at the same time — it is not the default, and an activity with no affinity cannot be re-entered by a `FLAG_ACTIVITY_NEW_TASK` launch, which is the other way an app "restarts" instead of resuming.)
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
- **The caller's identity is REPLACED by every event that carries a number, never merged.** `DialerState.copyWith` reads null as "leave it alone" — correct for every other field and wrong for these two — so a call from an **unsaved** number (`lookupContactName` answers null) inherited the *previous* caller's `activeName`, and a call telecom reports no subscription for inherited the previous `activeSubscriptionId`. That is both «شماره سیو‌نشده اسم نفر قبلی را نشان می‌دهد» and «شماره‌ای که از یک مخاطب حذف شده هنوز با اسم آن مخاطب زنگ می‌خورد»: the native `PhoneLookup` was right all along and its "nobody" could not be published. `clearActiveName` / `clearActiveSubscriptionId` say it, `_namesTheParty` gates them on the event actually carrying a phone (an AUDIO_STATE or hold change is about the call, not about who is on it), and every teardown — `_idleState`, EndCall, RejectCall, CALL_FAILED — clears both. Pinned by `test/unit/dialer_bloc_test.dart`.
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

### Leaving a call without ending it

A call used to own the screen until it was over: back hung up, and the phone that holds the dialer role has no other call UI to fall back on, so looking a number up or reading a message mid-call was impossible. Three pieces, and all three are needed — one of them alone strands the user.

- **Back and «کوچک کردن» minimize.** `InCallScreen` is wrapped in `PopScope(canPop: false)`; both go through `CallUiCoordinator.minimize()`, which removes the call route and sets `CallUiCoordinator.minimized`. `restore()` puts it back (or, when the route is merely buried under a page opened during the call, raises it). The chevron exists as well as the gesture because a back-to-minimize is not discoverable.
- **`ReturnToCallBar` is mounted from `MaterialApp.builder`, ABOVE the navigator.** The whole reason to leave the call screen is to open something, and everything the user opens is a pushed route — a bar any lower would vanish under the first conversation. It must not be re-parented when it appears: the app's Navigator hangs off it, so the tree **shape** is constant (Stack + MediaQuery always present, only the bar comes and goes) and the app is passed through `ValueListenableBuilder`'s `child`. It pushes the app down by raising `MediaQuery.padding.top` rather than drawing over it.
- **`CallInCallService.refreshOngoingNotification` posts the shade's «تماس در جریان» card** whenever a connected/dialling call exists and the call screen is not in front. On Android 12+ that `CallStyle.forOngoingCall` is also what produces the status-bar chip. It needs `callScreenShowing()` = `callUiForeground` (MainActivity onStart/onStop) **and** `callRouteUp` — leaving the call screen for another screen of the *same app* produces no lifecycle callback at all, so Dart reports it over `setCallScreenVisible`. Like the incoming card it carries a `fullScreenIntent` it never fires: a CallStyle notification tied to neither a foreground service nor a full-screen intent is rejected with `IllegalArgumentException`, and a crash here hands the call to the OEM dialer.
- **Tapping the card returns to the call.** Its content intent carries `EXTRA_RETURN_TO_CALL`; `MainActivity.consumeLaunchAction` turns it into a raw `SHOW_CALL_UI` event on the **call** stream (`NativeCallService.onShowCallUi`), not the launch-action map — `CallUiCoordinator` sits above the auth flow and must not wait for `MainNavigation`, which is behind the app lock.
- **The duration comes from telecom** (`Call.Details.connectTimeMillis` → `DialerState.callConnectedAt`), never counted by the screen. The screen can now be closed and re-opened, and a screen-local counter restarted at zero every time — as it also did on a cold start into a call that had been running for minutes. `formatCallDuration` prints «…», never «۰۰:۰۰», for a call with no connect time yet.
- `NativeCallEvent.unknown` exists so an event name this build does not recognise is a no-op. It used to fall through to `disconnected`, which reads as «the call ended» and tears a live call's UI down.

### «اندازه متن پیام»

A conversation is the one screen that is nothing but text, read by people of every eyesight, and Android's system font size is a poor answer — turning it up to read an SMS turns the whole phone up. One persisted value (`SettingsState.messageTextScale`), reached three ways: a two-finger pinch on the thread, «اندازه متن» in the conversation's overflow, and «اندازه متن پیام» in Settings → پیامک‌ها. The gesture and the rows write the same setting, so they can never disagree.

- **`MessageTextScaler` composes with the platform's scaling, it does not replace it.** `TextScaler.linear(ours)` would throw away Android 14's non-linear curve *and* whatever the user set system-wide, so a chat would render smaller than the rest of the phone for anyone using large text. It implements `==`/`hashCode` because `MediaQueryData` equality includes the scaler and a fresh unequal instance on every build would rebuild every text widget in the thread once a frame.
- **Applied to the thread and the composer, NOT the app bar** — a header at 200 % breaks its own layout, and Google Messages does not scale its chrome either.
- **`_PinchOnlyScaleRecognizer` refuses to win the gesture arena with one finger.** This is the load-bearing part: `ScaleGestureRecognizer` treats a one-finger drag as a pan and claims the arena for it, which would take the conversation list's scroll — the primary interaction on the screen — away in exchange for a gesture nobody made. Acceptance is *swallowed* rather than rejected, so a second finger landing a moment later still starts a real pinch.
- A pinch settles onto one of `MessageTextScale.steps` on release, so the gesture and the settings rows always name the same size, and it writes the preference **once**, on release.

### Links inside a message

`LinkifiedText` matches, in this order: full URLs (`http(s)://`, `www.`), **scheme-less links**, USSD codes, then runs long enough to be phone numbers.

- **The scheme-less rule is what makes a short link tappable.** Every URL shortener produces `b2n.ir/xK9`, `bit.ly/3aZ`, `mci.ir/-V52jyFF` — no scheme, no `www.` — and the pattern knew neither, so the single most common link in an Iranian SMS rendered as inert text. Two shapes, and the split is what keeps it off ordinary prose: a host on a **listed** TLD with the path optional (`digikala.com`), or a host on *any* alphabetic TLD **followed by a path** (`foo.bar/baz`). A lookbehind keeps it out of email addresses and out of the middle of a longer token, and every label must be ASCII — so «۱٬۵۰۰٬۰۰۰», «1.500.000», «نسخه 1.2.3» and «report.pdf» are all left alone (`test/unit/linkified_text_test.dart` pins each of those).
- `isWebLink` / `webUriOf` are the one place a tapped run is told apart from a phone number, and the one place the missing `https://` is added. The **preview card** (`firstUrl`) is deliberately still explicit-URL only: a bare domain is worth linkifying, not worth a network fetch.

### USSD codes inside a message

Iranian carriers send them constantly, and in a Persian SMS they were unusable for two independent reasons — both fixed in `UssdCode` + `LinkifiedText`.

- **They rendered backwards.** `*` and `#` are bidi-neutral and digit runs are European Numbers, so inside an RTL paragraph the algorithm resolves the separators to the paragraph direction and reorders the pieces: `*140*11#` came out as `#11*140*`. Every matched link — USSD, URL, phone number — is now drawn inside an **LTR isolate** (U+2066/U+2069). Render-time only: nothing stored ever carries those characters, because the DB row must stay byte-identical to what `content://sms` holds.
- **They were not tappable.** A tap opens `showUssdActionSheet` (شماره‌گیری / per-SIM rows / کپی کد). Which carrier answers is the whole question for a balance code, so the SIM rows are spelled out rather than hidden behind a long-press. The code goes to telecom through the normal `placeCall` path; `CallInCallService.onCallAdded` already drops MMI dials so no call screen flashes over the network's own dialog.
- **The shape rule is AOSP's** (`isMmiCode`): starts with `*`/`#`, ends with `#`. The trailing `(?![digits])` is what tells «#31#09121234567» — an MMI *prefix* on a real call — apart from a standalone code.
- **A mirrored code is put back into dialling order.** Verified on a live Irancell SMS: its Persian half stores «خرید بسته اینترنت: **#5*555***» — the sender typed the code in *visual* order so an RTL renderer would show «*555*5#». It reads correctly and is completely undialable. `UssdCode.correctedOf` reads forward first and only re-reads a run backwards when it is not a code forwards at all, so «#100#» (well-formed in both directions) is never flipped. This is the «اصلاح خودکار» half of the feature; the corrected text is what is drawn, copied and dialled.
- Persian **and** Arabic-Indic digits are folded to ASCII by `toDialable`; `PersianUtils.toEnglishNumber` only knows the Persian set.

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

### «گفتگوی جدید» — the recipient picker

`ContactSelectorScreen` is Google Messages' *New conversation* page, top to bottom: a «به:» field that collects the picked people as **chips inside the input**, one row to turn the list into a group selection, «گفتگوهای اخیر», then the whole address book in A–Z sections under a fast-scroll bar. Three modes, one screen — default (tapping a row opens that chat), `pickOnly` (pops a `PickedRecipient`, for «هدایت»), `pickMembers` (multi-select that pops `List<GroupMember>`, for «افزودن اعضا»).

- **It filters through the app's one matcher and orders by the app's one alphabet.** It used to carry a private `toLowerCase().contains` and a private `sortedKeys..sort()`, which is exactly why a contact saved as «+98 912…» could not be found by typing «0912…», «علي» did not find «علی», and پ چ ژ ک گ were scattered through the letters. It now goes through `ContactRepository.matchContacts` (→ `SearchText`) and `core/widgets/contact_index_list.dart`.
- **`core/widgets/contact_index_list.dart` is shared with the contacts tab** — sections, the header delegate, the alphabet bar, the row/header extents and the jump-offset maths. A second copy would be a fast-scroll that drifts: the jump only lands on the right name while the list's order, the bar's ranks and the row height agree. Anything drawn *above* the sections (the group row, «گفتگوهای اخیر») must be counted into `leadingOffset`, and must therefore have a fixed extent.
- **Picking somebody clears the typed text** (`_clearQuery`). The query answered its question the moment the chip appeared; leaving it behind keeps the list filtered to one name, so picking a second person means deleting the first search by hand — and the IME's composing region survives the rebuild and commits a stray character into the field (observed on the device: a leftover «m»).
- **«گفتگوهای اخیر» lists only dialable senders.** «Snapp», «MissedCalls» and the bank codes are the bulk of a real Iranian inbox and none of them can receive a reply, so an unfiltered suggestion list is a list of dead ends. Group threads are left out too — they already have their own inbox row.
- Search rows and the «ارسال به این شماره» row share the same 72 dp `_PickerRow` as the sections, name over `ContactNumbersLine`, because the extent feeds the fast-scroll offsets.

### Group conversations («پیام گروهی»)

**A group is a real conversation in this app, and the send is a fan-out.** There is no MMS here, so there is no provider thread that can hold several recipients — but that only decides where *replies* land, not whether the history can be shared. So: one thread, one bubble per send, N real SMS, and a one-time banner saying so. Google Messages with «Group MMS» off does the same thing (its replies also come back as 1:1 conversations); the earlier `BroadcastComposeScreen` — a one-shot mass-text composer that left nothing behind — was deleted.

**Storage (DB v22).** `message_groups` (id, optional title) · `message_group_members` (`normalized` = `PhoneNormalizer.toThreadId`, plus a denormalized `display_name`) · `message_group_targets` (one row per recipient per group message).

- **The thread id is `'g:' || groupId`** (`GroupThread`). Deliberately not a phone number, so it cannot collide with one, and deliberately still a plain `thread_id`, so paging, pinning, archiving, the unread count, the search, drafts and the per-thread SIM memory all work on it **without a single branch**. `getAllThreads` is unchanged; the group itself is joined on afterwards in `MessageBloc._resolveGroups`.
- **`message_group_targets` is the load-bearing table.** One group message = one `messages` row (`device_sms_id` **NULL**) + N provider rows, and the mirror-sync diffs the provider's id list against the ids the app knows. `MessageRepository.knownDeviceSmsIds` therefore UNIONs this table — without it the next sync would treat N-1 of those provider rows as new and import a copy of the group message into every member's 1:1 conversation. Verified on the device: three SMS written to `content://sms`, app force-stopped, full sync on restart, and the 1:1 threads stayed clean.
- A NULL `device_sms_id` on the message row also means the stale-row diff can never delete a group message.
- **The bubble's tick is the worst recipient's** (`GroupSendSummary`): a message three of four people got is not «ارسال شد», because the one it missed is the whole reason to look. «اطلاعات» opens the per-recipient list, and «ارسال مجدد» re-sends **only** the failed targets — never the whole group again.
- **Delivery reports are routed per recipient.** Each target carries its own `tracking_id` (a UUID) handed to the native send; `SmsService` asks `GroupRepository.applyTargetStatus` *before* the message-id path, then re-folds the aggregate. A tracking id can never collide with a message id — both are minted here.
- **Deletes name the provider rows one by one.** A group thread id is not an address, so `deleteSmsThreadFromProvider` has nothing to match; `deleteThreadGlobally` reads the target ids instead, soft-deletes the messages (the targets stay as the tombstones the sync needs) and drops the group row. `deleteMessagesGlobally` does the same per message rather than falling through to the body+timestamp fallback, which would delete by content across every address in a ±10 s window.
- **Group threads are excluded from the number search** (`_threadIdsMatchingNumber`): a UUID is full of digits and a numeric query would hit groups at random. They are found by *name or member* instead, matched in `MessagesListScreen._runSearch` and passed in as `alsoThreadIds`.
- **A group of one is not a group.** Picking a single recipient drops back to the 1:1 conversation, and removing the last-but-one member offers to delete the group — a second thread for a person who already has one would hide half their history from every other SMS app on the phone.
- **`findOrCreate` keys a group on its member SET.** Picking the same three people twice must land in the conversation that already exists, or the inbox fills with rows nothing can tell apart. A title supplied later (opening a label as a group) names a group that never had one; it never overwrites a name the user chose.
- **The title is derived until it is set**: one name, «علی و مریم», «علی، مریم و رضا», then «علی، مریم و ۲ نفر دیگر». Everybody is named while everybody fits — «و ۱ نفر دیگر» for a group of three is a worse header than the third name. `MessageBloc._onRefreshContactNames` refreshes the denormalized member names, so renaming a contact renames the group.
- **Scheduling is off in a group.** A `scheduled_messages` row carries one phone number and is delivered by a native worker that knows nothing about groups, so the affordance is withheld (`onSchedule: null`) rather than accepted and quietly mishandled.
- Entry points: «شروع گفتگوی گروهی» in the picker, and «پیامک گروهی» on a label page (which names the group after the label).
- **Labels are an accordion above the contacts** in group mode — not a Google feature, an addition, and it earns its place because a group is nearly always one the phone already knows about. Tapping a label reads its members natively (`ContactGroupsService.memberIds`) and selects them; tapping it again removes exactly those. Collapsed by default, so the address book keeps its height.

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

**The caption under a bubble is drawn ONLY for the tapped message** (`ConversationScreen._expandedMessageId` → `MessageBubble.expanded`) — time, SIM badge, «پیامک», the tick and its word («در حال ارسال» / «ارسال شد» / «تحویل داده شد» / «ارسال نشد»). Tapping again collapses it, only one bubble is open at a time, and the rule is identical for a received bubble and a sent one. It used to *also* appear by itself under the last bubble of every group and under any bubble followed by a 10-minute gap (the old `showTimestamp`), which put a row of grey captions nobody asked for through the whole thread while a message in the middle of a burst still could not say whether it had arrived. The tick alone is not readable either — «✓ vs ✓✓» is a convention this app never taught anyone — and the alternative was the long-press overflow's «اطلاعات», three gestures to answer "did it arrive". Long-press still opens the action overlay; the tap is ignored while a selection is running. The **failed** row is the one exception and is always visible: it is an error the user has to act on, not chrome.

### A refused send keeps the message

**The row is written BEFORE the radio is touched, as `pending`.** `SmsService.sendSms` used to persist only after the native send returned, so a send in airplane mode left *nothing at all* behind: the composer cleared, no bubble ever appeared, and the message the user had typed was gone. It now inserts the row, broadcasts it (`_sentController` → the bubble appears with ⏱), hands it to the radio, and writes the outcome back — `applySendResult` on success (status, the moment the radio accepted it, the provider row id, the SIM it really went out on) or `failed`.

- **`_transmit` is the one place** the first send, «ارسال مجدد» and the scheduled deliverer all go through, so what a success records and what a failure leaves behind cannot drift between them.
- **A failed row is local-only** (`device_sms_id` null), which the mirror-sync's stale-row diff never touches — so it survives every resume and restart until the user retries or deletes it.
- **`MessageBubble._failedRow` replaces the timestamp row** with «⊙ ارسال نشد · برای تلاش مجدد ضربه بزنید» in red; the whole row retries. A failed message that also printed «✓ پیامک» read as half-sent. «ارسال مجدد» is also first in the long-press overlay.
- **Retry re-sends the SAME row** (`RetryMessage` → `SmsService.resendMessage`), keeping its id, its place in the thread and its star. It used to dispatch a fresh `SendMessage`, which left the failed bubble behind and stacked a second copy under it. A row that is not `failed` is refused, so a double tap cannot send twice.
- **The scheduled deliverer passes `optimistic: false`.** A scheduled row owns its own retry and backoff (`ScheduledMessage.withFailedAttempt`), so an optimistic insert would leave one dead «ارسال نشد» bubble in the conversation *per attempt* for a message that is still going to be sent. On that path a failure leaves nothing and a success inserts the finished row in one go.

**`MessageSent` / `MessageSendFailed` / `MessageError` are one-shot NOTIFICATIONS, not screen states** — and they travel through the same state channel, which is what made the bug above look like data loss. The inbox answers both send outcomes with a `LoadThreads`; finding a state that is neither a loaded inbox nor a loaded conversation, `_onLoadThreads` emitted `MessageLoading` over the open chat and then a `ThreadsLoaded` the chat's `buildWhen` ignores — so the conversation sat on a spinner **for ever**. Two things keep that shut:

- `MessageBloc._lastDurable` (maintained in `onChange`) is the last `ThreadsLoaded`/`MessagesLoaded`. The loading guard asks *it*, never `state`.
- `_notify` emits the notification and then puts the bloc straight back on `_lastDurable`, so it is never left parked on one.
- `ConversationScreen` reloads itself on `MessageSendFailed` as well as on `MessageSent`: the bloc is global, so by the time a *second* refused send lands it is sitting on `ThreadsLoaded` and `_mergePersistedMessage`'s fold-into-the-open-conversation path gives up.

### The sides of a chat are physical, not directional

`MessageBubble` lays its row and column out with `textDirection: TextDirection.ltr` inside an otherwise RTL conversation: **sent right, received left**, the arrangement every messenger uses, Persian ones included. Left as directional alignment, `MainAxisAlignment.end` resolved to the *left* under the screen's RTL direction, so the user's own messages ran down the left while their tail corner — a plain, non-directional `BorderRadius.only` — still pointed right. The bubble's own text keeps the ambient RTL direction: a `Flex`'s `textDirection` decides how that flex lays its children out and nothing else.

Everything that positions itself against a bubble follows the same rule and had to be swapped with it: `message_action_overlay` anchors the lifted copy's zoom (`isSent ? centerRight : centerLeft`) and hangs the action card off the bubble's own edge (`isSent ? anchor.right - width : anchor.left`), and `ScheduledBubble` — an outgoing ghost — pins its column to `ltr` too, or it sits on the opposite side from the sent messages around it.

### Long-press & selection

Long-press is the *same gesture everywhere*, matching Google Messages / Phone / Contacts:

- **Chat bubble → lift, zoom, select text.** `MessageBubble` (stateful, holds a `GlobalKey` on its box) measures the bubble's global rect *and* where inside it the finger landed, then hands both to `showMessageActionOverlay` (`widgets/message_action_overlay.dart`). The overlay is a `PopupRoute` that blurs the backdrop, animates the bubble from its list position to a lifted one at `_kZoom`, and makes the body selectable — the Telegram flow. The action card (ستاره / کپی / هدایت / اطلاعات / انتخاب / حذف) hangs off the bubble's own edge.
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

### MessageBloc state guards

- `LoadThreads` does **not** emit `MessageLoading` if the current state is already `ThreadsLoaded` or `MessagesLoaded` — this prevents the chat screen going blank when a background SMS triggers a thread refresh.
- `_cachedPhoneToName` is built once per session and reused by `_resolveContactNames` to enrich threads with device contact names without hitting the contact store on every tab switch. While that map is still cold `_emitThreads` emits the rows **twice** rather than holding the inbox back for an address-book read that may be queued behind another `DeviceSyncQueue` job — but the first emit is **not bare**: it is named from `ContactNameCache` (SQLite, see the schema invariants), so a launch whose address book has not changed paints the finished inbox once and the second emit is dropped as an equal state.
- **`_applyNames` overwrites, and an unmatched number is *untitled*.** It used to keep any name a row already carried, which reads as an optimization and is a bug: `RefreshContactNames` re-resolves the rows already on screen, so a contact the user had just deleted went on titling its conversation until something happened to re-read the inbox from SQLite. Group rows are skipped — their title comes from the group, not the address book. `MessageThread.copyWith` needs `clearContactName` for the same reason `DialerState.copyWith` needs `clearActiveName`: a plain null means "leave it alone".
- `LoadMoreThreads` / `LoadMoreMessages` carry an in-flight flag (`_loadingMoreThreads`, `_loadingMoreMessages`). The `hasMore` guard alone is not enough: it only flips once the previous page *returned*, so a fast fling dispatched one event per scroll notification and the bloc ran a dozen paged queries back to back — the multi-second stall while scrolling the inbox.
- `MessageRepository.getAllThreads` pages inside a `page` CTE that carries nothing but (thread_id, last_ts, is_pinned); the per-thread work (last-message rowid pick, unread count) runs only on the rows that survived `LIMIT`. Flattening it back re-introduces a correlated subquery per message row of the whole table.
- **A refresh must not shrink the paged-in inbox.** `_loadedThreadCount` / `_loadedArchivedCount` (kept apart per inbox, updated in `_emitThreads` and `_onLoadMoreThreads`) raise the limit of any `LoadThreads` at offset 0 to however many rows are already on screen. A plain `LoadThreads()` carries the default limit of 50 — returning from a conversation, resume or a send used to cut a 200-row list back to 50 underneath the user, which collapsed the scroll position to the top.

**A queued send floats its row to the top of the inbox**, exactly as a draft does — `MessageThread.scheduledText`/`scheduledTime` feed `sortTime`, and `ThreadTile` draws a ⏱ preview (draft still wins). Scheduling for somebody far down the list used to leave their row exactly where the last delivered message had put it, with nothing anywhere to say a message was waiting. The overlay is merged in `MessagesListScreen._mergeOverlays` from the (global, non-lazy) `ScheduledMessageBloc`, so the inbox needs no query of its own and the row drops back the instant the message is delivered or cancelled; `ScheduledLoaded` is Equatable over its rows, so the deliverer's 30 s tick does not rebuild the list. A schedule to a number with no conversation yet is a synthetic row like a draft's — and, having no thread behind it, it takes no swipe and no multi-select.

**Search results are a snapshot, so every mutation re-runs the query.** `_searchResults` answers one query and is not a view of the inbox, so deleting, archiving, blocking, pinning or marking a *search hit* left the row sitting on screen — the action looked like a no-op, and leaving the search showed it had happened all along. A `BlocListener` on `ThreadsLoaded` re-runs `_runSearch` instead: the inbox emit is the authoritative "the table changed" signal (every one of those actions answers with one), it arrives *after* the write rather than racing it, and `ThreadsLoaded` being Equatable means an emit carrying nothing new never reaches the listener. The selection actions also read `_visibleThreads` (results while searching, inbox otherwise) — sourcing them from `_lastInbox` alone meant «سنجاق» and «مسدود کردن» found nothing to act on for a thread that had never been paged into the list.

**A conversation screen only ever renders its OWN thread.** `MessageBloc` is global and holds one conversation at a time, so a chat opened on top of another (tapping a number inside a message, «هدایت») parks the bloc on *its* thread while the screen underneath is still mounted and still rebuilding — which is why coming back showed the second conversation's messages under the first one's header. `ConversationScreen._isMine` filters every read by `state.threadId`, `_lastLoaded` keeps the last page of this thread to paint from (a spinner only when there is genuinely nothing of it yet, the `_lastInbox` pattern), and the screen is `RouteAware`: `didPopNext` re-dispatches `LoadMessages` and takes back `setVisibleThread`, which the chat above it had claimed.

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
- **…and a conversation it has never sent on answers on the card the message ARRIVED on.** `ThreadSimRepository.initialSimFor` is three answers in order: what this thread last sent on, else `MessageRepository.lastIncomingSubscriptionId` (the newest *received* row's SIM), else the system default. The middle one is the whole of «someone wrote to me on SIM 2 and my reply went out on SIM 1»: only the user's own past sends used to count, so a first reply always left on the pinned default — from a number the other side had never written to — and the native quick-reply, which has always answered on the arrival card, disagreed with the app's own composer. Memoized per thread (misses included), dropped on receive (`invalidateIncoming`) and after a device import (`clearIncoming`), and the conversation re-seeds on `SimService.revision` because a call/SMS routinely wakes a dead process and the roster can land after the screen does.
- **The picker only appears when there is a real choice**: two SIMs *and* no system default pinned (`SimService.defaultFor`). Second-guessing the user's Android setting is the bug, not the feature. `placeCall` (`core/sim/sim_call.dart`) is the ONE dial path in the app for exactly this reason — do not call `NativeCallService.makeCall` directly.
- **…but there is ALWAYS an explicit override**, or a pinned default makes the other card unreachable from the app — which is exactly what the first pass got wrong. Two affordances, both through `placeCallPickingSim`: a **long-press on every call button** in the app, and the explicit «تماس با سیم …» rows `simCallRows` adds to the call-log / favourites / number sheets.

**There are no SIM chips.** Google Messages and Google Phone show none, and neither does this app any more:

- The **composer** chip is gone. Which card a conversation sends on is a property of the conversation, asked once — a pill wedged between «+» and the hint text read as part of the composer's furniture. It lives on the conversation's details page instead (below).
- The **keypad** chip beside the call pill is gone, with `SelectDialSim` / `DialerState.dialSubscriptionId` deleted rather than left dispatching from nowhere. The card is Android's own default; when nothing is pinned the picker opens on the dial itself (`resolveVoiceSim`), which asks at the moment it matters instead of parking a control on the keypad for ever.
- **`ConversationDetailsScreen`** (`messages/screens/conversation_details_screen.dart`) is Google Messages' details page and is what tapping the conversation header now opens — avatar, name, number, تماس / اطلاعات مخاطب, the **«ارسال با» card with «تعویض»**, then اندازه متن · بایگانی · مسدود · حذف. The header used to go straight to the contact page, which an unsaved number does not have and which is the wrong home for a per-conversation setting. Everything that ends the conversation comes back as a `ConversationDetailsOutcome` rather than being done there — the delete has to take the provider rows with it and the conversation is the screen holding the thread, the same split `GroupDetailsScreen` uses.
- **The card always names a concrete SIM**: the conversation's remembered one, else Android's pinned SMS default, else slot 1 (`ThreadSimRepository.defaultSim`). A page whose job is to print «which card does this go out on» cannot print «none», so the fallback exists and the *send* uses exactly the card that was shown. It replaces the old unset-chip "ask every time", which had no surface left once the chip went.
- **The send pre-flight is per-SIM.** `SmsHandler.isInService(subscriptionId)` builds a `TelephonyManager.createForSubscriptionId`; reading the *default* subscription's `ServiceState` made the two cards lie about each other — a send on SIM 2 refused with NO_SERVICE because SIM 1 had no signal, and a send on a card that genuinely had none sailing past the check into the radio queue (which reads to the user as "it sent, very late").
- **`SimRegistry.subscriptions` is cached** (30 s TTL, dropped by `OnSubscriptionsChangedListener`). It is several binder round-trips — plus one per SIM for the card's own number on API 33+ — and it sits on the incoming-SMS notification path (twice) and on every telecom call-state change. `withNumbers` is opt-in and uncached: only the Dart picker displays numbers.
- **Never rebuild a `MessageModel` field by field — use `copyWith`.** `MessageBloc._onMessageStatusChanged` and `_mergePersistedMessage` did, and each silently dropped whatever field was added last: a bubble lost its SIM badge the instant its ✓✓ landed and only got it back on the next read from the DB.
- **Scheduled messages carry `subscription_id`** and `ScheduledSmsWorker` (Kotlin) resolves null to the system default before sending, so the send, the provider row and the chat row all name the same card. Change it with `scheduled_message_model.dart`, as ever.
- **A card going into the phone is not something the element tree can notice.** Every affordance reads the *static* roster synchronously inside `build` (a bubble's badge cannot await a channel), which is correct and is also why the app stayed single-SIM-shaped until it was killed and reopened. `SimService.revision` is bumped whenever the roster or the pinned defaults change, and `SimAware` (`core/sim/widgets/sim_picker.dart`) is the one-line wrapper that turns it into a rebuild — used by the conversation, «اخیر» and the details card. Screens that only read the roster at *gesture* time (a long-press picker, an action sheet) need nothing; the static cache is already current by then.
- **The call screens read the roster through `SimAware`, not once in `build`.** A ringing call is the single most likely thing to wake a dead process, so `IncomingCallScreen` / `InCallScreen` regularly paint before `SimService` has answered — and a one-shot read then decides the phone is single-SIM and prints «تماس ورودی» with no card on it, for the whole call. Both call `ensureLoaded()` from `initState` and wrap the carrier line in `SimAware`. The incoming-call **notification** names the card too (`CallInCallService.subscriptionOf` → `SimRegistry.labelOf`, multi-SIM only): on a locked phone that card is often the only thing the user sees of the call.
- **The roster event does not carry the derived state.** On a change, `SimService._refreshDerived` re-reads `getDefaults` and `getPhoneAccounts`. Without it the roster updated live while `defaults` still said «single SIM, nothing pinned» and the account map still had one entry — so the picker had nothing to pick and every new call was logged with no SIM.

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
