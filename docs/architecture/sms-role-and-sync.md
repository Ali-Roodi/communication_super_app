# Default SMS app role, device mirror-sync and notifications

Part of the architecture notes for this repo. Index and the rules that apply everywhere: [`DEVELOPER_GUIDE.md`](../DEVELOPER_GUIDE.md).

### SMS pipeline

**Receiving:**
1. `SmsHandler.kt` (Android) registers a `BroadcastReceiver` for `SMS_RECEIVED`.
2. Events are pushed to Flutter via `EventChannel` (`com.example.communication_super_app/sms_events`).
3. `NativeSmsService` (Dart) wraps the `EventChannel` stream. Call `initialize()` exactly once — a second call is a no-op (guarded by `_initialized`).
4. `SmsService.listenToIncomingSms()` subscribes to `NativeSmsService.onSmsReceived`, persists the message, shows a notification, and calls `onMessageReceived` callback → `MessageBloc.add(ReceiveMessage(...))`.
5. The listener is registered at most once per session (`_listening` guard). `MessageBloc` starts it on the first `LoadThreads` event.

**Encrypted SMS (`#E:`) take a different road** in every step above: not written to `content://sms` (`SmsDeliverReceiver` skips it, sends pass `private: true`), not persisted into `messages`, not notified by `SmsNotifier`, skipped by the mirror-sync. The receivers park the ciphertext in `secure_queue` and post a bare «پیام رمز جدید». Details in `editions.md` (phase F).

**So do a hidden-phonebook contact's SMS, plain or encrypted** (phase G): `SmsDeliverReceiver` skips the provider, `HiddenSms.receive` seals the whole message into `sealed_queue` before either receiver's normal path, `querySms*` filter the number out of the mirror-sync, and `SmsService.sendSms` refuses it (`HIDDEN_NUMBER`). See `editions.md`.

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

**Every provider call of `CallLogSyncHandler` runs on its own thread** (`offMain`, one thread so a delete and the read after it stay in order) and answers on the main one. They ran on the main thread, and the first import of a long call history on a fresh install held it — and every touch — for as long as the read took. The ContentObserver and `ensureObserving` stay on the main thread; they are not reads.

**So: no plugin in this app may request a runtime permission.** Every grant goes through `PermissionGate`, and a plugin that opens its own dialog both double-asks and — since these plugins keep exactly one `Result` — dies the moment two calls overlap. The native handlers never ask: a missing grant surfaces as a `SecurityException` mapped to `PERMISSION_DENIED`, which the Dart side treats as "cannot read" (keep the mirror) rather than "nothing there" (wipe it). Row mapping (`CallLog.Calls.TYPE` → `CallType`) is deliberately done in **Dart**, so a constant this build has never heard of still arrives intact.

### SMS notifications (single native pipeline)

ALL incoming-SMS notifications are posted natively by `SmsNotifier` — from the live dynamic receiver (`SmsHandler`) and the cold-start `IncomingSmsReceiver` alike. `NotificationService` has **no SMS path at all** any more (the one it kept "for a telephony fallback" had no callers and was deleted); never add a Dart-side SMS notification back, it would duplicate the native one.

- Actions are fully native (`SmsNotificationActionReceiver`): inline reply via RemoteInput (sends with SmsManager + provider write-through + app-DB insert), mark-read (direct DB update) and **«مسدودسازی»** (a `blocked_numbers` row of the same shape `BlockedNumbersRepository.block` writes, four base columns only so an older schema takes it too). They work with the app dead.
  - **The card is dismissed whatever the database does.** «خواندم» used to dismiss only *after* its UPDATE, and an UPDATE that threw — the app's own connection holding the write lock past the busy timeout, which a mirror-sync or an import does for seconds — skipped the dismiss: «بعضی اوقات دکمه خواندم کار نمی‌کند». Writes now go through `withDbRetry` (a few attempts, spaced) and the dismiss is unconditional. The reply path had the same flaw with a worse outcome: the SMS was already sent, and a card still standing reads as "not sent", so the user sent it twice.
  - **Every action tells the running app** (`MainActivity.notifyThreadChanged` → intents channel `threadChanged` → `DeepLinkService.onThreadChanged` → `MessageBloc.ThreadChangedExternally` + `BlockedNumbersBloc.LoadBlocked`). The inbox was painted from the rows the action just changed, and without the nudge a thread read from the shade stayed bold in an open app until the next resume.
  - «مسدودسازی» replaces the card (same tag and id) with a silent «… مسدود شد» that carries «لغو» for `BLOCKED_CARD_TIMEOUT_MS` (30 s). The undo removes exactly the row the block inserted (`EXTRA_BLOCKED_ROW_ID`); blocking a sender who was already blocked offers no undo, because there is nothing of ours to take back. 8 s was tried first and was gone before the card could be pulled down and expanded on One UI, which shows it collapsed. A write that never lands posts «… مسدود نشد» rather than pretending.
- Notifications are tagged with the threadId; opening a conversation calls `clearThreadNotifications` and `setVisibleThread` over the intents channel — `SmsNotifier` suppresses notifications for the visible thread while the activity is resumed.
- Tap deep-links go through **one** channel: `MainActivity.consumeLaunchAction` returns a typed `{type: thread|dial|sms, …}` → `DeepLinkService.LaunchAction` → `MainNavigation._handleLaunchAction` (cold start: `consumeInitialAction`; warm: `onNewIntent`). Registered post-auth so a tap never bypasses the app lock, and the extra/`intent.data` is stripped as it is consumed so it cannot replay on the next resume.
  - `thread` is the SMS notification's `threadId`. `dial` is another app's `tel:` (ACTION_DIAL/VIEW) → the keypad sheet opens **prefilled** (`showDialerBottomSheet(initialNumber:)`), which is what "call this number I selected in a browser" does in Google Phone. `sms` is `sms:`/`smsto:`/`mms:` or a shared `text/plain` → the conversation with the body already in the composer, or `ContactSelectorScreen(initialText:)` when there is no recipient.
  - **The share sheet needs its own manifest filter**, and that is why هم‌رسان was missing from the list of apps a shared piece of text could go to. `ACTION_SEND` carries its payload in `EXTRA_TEXT` and has **no data URI at all**, so the `sms:`/`smsto:` filter (which requires one) can never match it — both halves of the code had always handled the intent and nothing advertised it. A separate `<intent-filter>` of `SEND` + `DEFAULT` + `mimeType="text/plain"` is the whole fix; do not fold it back into the scheme filter.
  - An opaque `sms:…?body=` URI **throws** from `getQueryParameter` — the query is parsed by hand and `Uri.decode`d.
- **The conversation resolves the contact name itself** rather than trusting what it was pushed with. Opened from a notification it had only a number, so a saved contact showed as an unknown one *and* got the «گزارش هرزنامه» prompt; it now reads the contact cache synchronously and falls back to an async lookup, and the spam prompt waits for that answer (`_contactResolved`) instead of assuming.
- **The small icon is a white-on-transparent silhouette** (`@drawable/ic_stat_message`, and `ic_stat_call` for the three call cards), never `applicationInfo.icon`. A notification's small icon is not a picture: the system throws away every channel but alpha and tints what is left, so the *adaptive launcher* icon this used to be — a full-colour square with no transparency anywhere — was drawn as a featureless blob. There was no way to tell from the status bar which app had something to say, which is half of «نمی‌شه فهمید پیام اومده».
- **Suppressing the notification for the open conversation asks whether the user can SEE it**, not only whether the activity is resumed (`MainActivity.isResumed && visibleThreadId == threadId && isUserWatching(context)`, where watching = `PowerManager.isInteractive && !KeyguardManager.isKeyguardLocked`). On any OEM build that resumes the foreground activity *behind* the keyguard — which is exactly what `showOverLockScreen`'s gate exists for — waking a locked phone put MainActivity back in `onResume` with the lock screen still on top, and every further message from the last-opened conversation was then dropped on the floor. A user who cannot see the screen cannot have read it. `setVisibility(VISIBILITY_PRIVATE)` is likewise spelled out rather than left to the platform default.
  - Whether the lock screen draws a *card* or only the status-bar icon is the phone's own setting (One UI: «سبک اعلان بازشو» / lock-screen notification view style). Verified on the SM A336E by posting a control notification from `cmd notification post`: it behaved identically, so a missing lock-screen card is not something the app can fix from here.
- Blocked numbers are enforced in BOTH receive paths natively (`BlockedNumbers.isBlocked` mirrors `PhoneNormalizer`) and in the Dart listeners; `SmsDeliverReceiver` also skips the provider write, and `CallInCallService` rejects ringing calls from blocked numbers before any UI. Missed calls post a native «تماس بی‌پاسخ» notification (default-dialer duty).
- **One card per conversation, `MessagingStyle`, and it stacks the UNREAD messages only** (`recentMessages`: `type = 'received' AND is_read = 0`, newest `HISTORY_LINES`, read straight from the app's SQLite because this runs with the engine dead). The id is `threadId.hashCode()`; a long-lived shortcut (`setShortcutId` + `setLocusId` + `pushConversationShortcut`) is what moves it into the shade's conversation section and makes the **expand chevron** work — before this it was one notification per *message*, each with a single line and nothing to expand to. It briefly replayed the last five rows of any type, which showed the user their own replies and messages they had already read; a notification is the list of what has not been seen.
- **The launcher badge is the count of the cards this app has posted, so a card that no longer stands for anything unread must be dropped — `SmsNotifier.reconcile`.** A card used to be cancelled only where it was posted from: opening the conversation (`clearThreadNotifications`) or the «خواندم» action. Every *other* way a message stops being unread left it up — marking a thread read from the inbox, deleting the conversation, blocking the sender, reading it on another device that writes into `content://sms` — and the launcher went on counting it, with no way for the user to clear it **by reading their messages**. That is the reported «یک عدد ۲ روی لوگوی برنامه … هرچی هم اپ رو می‌دیدم، اون عدد پاک نمی‌شد», and blocking made it worse in the other direction: the sender's card stayed while their conversation left the inbox, so the badge outlived the only screen that could have cleared it.

  `reconcile` walks `activeNotifications`, and cancels a card when its thread has **no unread received row left** or its sender is **blocked** — both read straight from the app's SQLite, because this runs with the engine dead as often as not. Anything it cannot read is left alone: dismissing a card we are not sure about silently swallows a message, which is far worse than a stale badge. Ours are the only *tagged* notifications the app posts (the three call cards use bare ids), and the channel is checked as well only where the API allows it — `Notification.getChannelId` is API 26 and would throw a `NoSuchMethodError` (an `Error`, not an `Exception`) on 24/25.

  It is called from `MainActivity.onResume` **and** from Dart (`DeepLinkService.reconcileNotifications`) on resume and after block / delete-thread / mark-read. Both, deliberately: a resume that never reaches Dart (engine still warming, a cold start straight into the call screen) still has to clear the badge.

- **The card carries `setNumber(unread + 1)`.** OEM launchers that draw a *number* on the icon (One UI among them) read `Notification.number`; without it they guess — counting cards, or counting the messages inside the `MessagingStyle` — and the icon's number drifts from anything the app believes. `unreadCount` excludes the announced message's timestamp for exactly the reason `recentMessages` does (the live path posts before Dart persists the row, the cold-start path after), so `+ 1` is right on both paths and the number always equals the messages the shade is showing.

- **«پنهان کردن محتوای اعلان‌ها» — while the app is locked, a card names nobody** (mentor's request, 1405/07/22, every edition, on by default). `NotificationPrivacy.hideContent` → `SmsNotifier.privateCard`: «پیام جدید» / «N پیام جدید», «برای خواندن، برنامه را باز کنید», no MessagingStyle, Person, avatar or conversation shortcut, and **no actions** (reply/mark-read/block would act on the sender from outside the lock). The tap still deep-links into the thread, behind the PIN. The missed-call card does the same («تماس بی‌پاسخ», no name/number/photo/actions); the «… مسدود شد» confirmation says «فرستنده». It is **"app currently locked"**, not "PIN set" (the first version was the latter, and was reported: «وقتی برنامه باز هست نباید حالت مخفی باشه»). "Locked" means *opening the app now would ask for the PIN*, so it is decided by `AppLockSession` (`security/`, process memory, a new process is locked): open while the app is on screen and unlocked, and still open in the background for the «قفل خودکار» window — counted natively from `MainActivity.onStop`, because Dart may not run again before it ends. Dart reports every change (`AuthRepository.reportSession`, chained so a lock is never overtaken by the unlock before it; and from `AppLockWrapper` once a return has decided whether it re-locks); `onDestroy` locks (the Dart session dies with the engine). A card posted in full while open carries `NotificationPrivacy.revealing` extras, and when the session locks — the window's alarm (`AppLockSession.DeadlineReceiver`, which also covers a process that died meanwhile), «فوراً» on leaving, a re-lock, `onDestroy` — `privatizeActive` re-posts each one silently as the private card under its own tag and id. Without that fold, a card shown while the app was open would stay readable in the shade after it locked, which is why the first version did not try.
  - The flag is mirrored by `NotificationPrivacySync` (Dart) as `PIN && switch`, on every settings load and after every PIN change in `AuthBloc`. Until Dart has written it once (the first launch after the update) it falls back to whether `flutter_secure_storage`'s file holds an `app_pin` entry (name only, never the value) — agreeing with the switch's default, so an update never announces a PIN-protected app in clear. A read error answers "hide".
  - The **incoming-call card still shows the caller**: deciding whether to answer needs it, and it is a live call, not a record left in the shade.
- **The carrier's own missed-call SMS is not a second notification.** Iranian operators text «تعداد ۱ تماس از 0912… داشته‌اید» from an alphanumeric sender for a call this app — the default dialer *and* the default SMS app — already posted «تماس بی‌پاسخ» for. That is the reported "one missed call, two notifications, and the one labelled «تماس» can't call back" (tapping the SMS opens a chat with `MissedCalls`). `CallInCallService.markMissedCall` stamps the number into SharedPreferences (30-min TTL, survives process death because the SMS often lands after the app is gone) and `SmsNotifier.isRedundantMissedCallSms` drops **only the notification** when all three hold: a non-dialable sender, a body naming a number marked missed, and wording that is about a call. The message is still delivered and still in the inbox. Do not weaken the marked-number condition to a body-pattern guess — the cost of a false positive is a silently swallowed notification.


## The second tick means delivered

`SmsHandler.SmsDeliveredReceiver` reads the **status-report PDU**, never the
broadcast's `resultCode`.

The platform documents the delivery `PendingIntent` as carrying "the raw pdu of
the status report" in the `"pdu"` extra and says nothing about a result code —
and on the RILs this app runs on the code is `Activity.RESULT_OK` for *every*
report the network sends, including «temporary error, still trying» and
«permanent failure, gave up». Trusting it is exactly the reported bug: ✓✓ on
messages that had not been delivered, and some that never would be.

TP-Status is TS 23.040 §9.2.3.15, read the way AOSP Messaging reads it:

| TP-Status | meaning | what the bubble does |
|---|---|---|
| `0x00`–`0x1F` | delivered | ✓✓ |
| `0x20`–`0x3F` | temporary, SC still trying | **nothing** — another report is coming |
| everything else | permanent failure | «ارسال نشد» |

A CDMA report (`format == "3gpp2"`) carries no TP-Status — `getStatus()` returns
`STATUS_ON_ICC_*` there, a different field — so it is treated as a plain
delivery. An unreadable/absent PDU is treated as delivered too: the report only
exists because the network sent one, and the alternative is a tick that never
advances on those phones.

**A multipart message reports per part.** `PartTally` counts them: ✓ and ✓✓ need
*all* parts, any failed part fails the message, and a failure is final so the
remaining parts cannot flip the bubble back. Without it a three-part SMS turned
✓✓ as soon as the *first* part was acknowledged. `expect()` is called **before**
`sendTextMessage` — the radio can acknowledge a part before the sending
coroutine gets another slice, and a report with no tally is treated as the whole
message.

## The dynamic SMS receiver carries BROADCAST_SMS

`SmsHandler.registerReceiver` registers the live `SMS_RECEIVED` receiver with
`Manifest.permission.BROADCAST_SMS` as the **sender** permission. It must stay
`RECEIVER_EXPORTED` (a system broadcast comes from another UID and Android 13+
drops it otherwise), and exported *without* that permission means any app on the
phone can forge an incoming SMS into this one — persisted into the inbox and
posted as a notification from a sender the user has no reason to doubt. The
manifest twin (`IncomingSmsReceiver`) has always been declared this way; the
dynamic one had not.

## Notification icons: small says what, large says who

A notification's **small** icon is alpha-only artwork the system tints into the
status bar (`ic_stat_message`, `ic_stat_call`). Most OEM shades — the tester's
included — render the card itself with the **app's launcher icon** unless the
notification supplies a large icon, which is why an SMS and a missed call looked
identical on their lock screen.

So both kinds now always set a large icon: the contact's photo, or
`NotificationAvatars.letterAvatar` — the same coloured circle with an initial
that the rest of the app draws for a contact with no picture (a number-only
"name" gets the plain disc; a circle with «۰» in it says nothing). The colour is
keyed on the **normalized number**, not the display name, because the name
arrives as the number on one path and as the contact on another, and a circle
that changes colour between two notifications reads as two people.
