# The conversation screen: bubbles, composer, emoji, links

Part of the architecture notes for this repo. Index and the rules that apply everywhere: [`DEVELOPER_GUIDE.md`](../DEVELOPER_GUIDE.md).

### «اندازه متن پیام»

A conversation is the one screen that is nothing but text, read by people of every eyesight, and Android's system font size is a poor answer — turning it up to read an SMS turns the whole phone up. One persisted value (`SettingsState.messageTextScale`), reached three ways: a two-finger pinch on the thread, «اندازه متن» in the conversation's overflow, and «اندازه متن پیام» in Settings → پیامک‌ها. The gesture and the rows write the same setting, so they can never disagree.

- **`MessageTextScaler` composes with the platform's scaling, it does not replace it.** `TextScaler.linear(ours)` would throw away Android 14's non-linear curve *and* whatever the user set system-wide, so a chat would render smaller than the rest of the phone for anyone using large text. It implements `==`/`hashCode` because `MediaQueryData` equality includes the scaler and a fresh unequal instance on every build would rebuild every text widget in the thread once a frame.
- **Applied to the thread and the composer, NOT the app bar** — a header at 200 % breaks its own layout, and Google Messages does not scale its chrome either.
- **The pinch is a raw `Listener`, NOT a `ScaleGestureRecognizer`, and that is not a style choice.** With a recognizer the pinch only ever worked when both fingers landed within a few milliseconds of each other — «حتما باید انگشت‌ها همزمان روی صفحه باشه» — and no amount of tuning could fix it, because the reason is structural. The list's `VerticalDragGestureRecognizer` sits *below* `PinchTextScale` in the hit-test path, so it is the first member of every pointer's arena; the moment one finger passes touch slop it accepts and every other member is **rejected**, and rejection runs through `OneSequenceGestureRecognizer.rejectGesture` → `stopTrackingPointer`. By the time a second finger arrives the scale recognizer is no longer tracking the first and can never see two. It cannot win the *second* pointer's arena either: an already-accepted drag recognizer rejoins each new pointer's arena accepted, while a scale recognizer needs movement before it may claim anything, so the sweep hands that arena to the drag as well. (The old `_PinchOnlyScaleRecognizer` swallowed its own *acceptance* for one finger. That addressed a different half of the problem — not stealing the scroll — and never this one.)

  A `Listener` takes part in no arena and is handed every pointer that hit-tests to it whatever any recognizer decides, so the second finger starts a pinch whenever it arrives: mid-scroll, a second later, either order. `_PinchTextScaleState` tracks the pointers itself and takes the baseline span when the second one lands (or as soon as the two separate past `_minSpan`, so a two-finger tap does not divide by ~nothing).

- **The list is frozen for the duration, through `PinchScope`.** A `Listener` steals nothing, which means the drag recognizer is still live and would scroll the thread under the pinch. `PinchScope` is an `InheritedNotifier<ValueNotifier<bool>>`; the thread's `ListView` reads it for its `physics` and becomes `NeverScrollableScrollPhysics` while two fingers are down. `Scrollable.setCanDrag(false)` cancels the live drag and the new `ScrollPosition` absorbs the old one's pixels, so nothing jumps, and the finger still on screen cannot carry the pinch's movement into a fling.
- **`_gain` (1.6) is the sensitivity.** The raw finger ratio needed a ~15 % spread for one step, which made even a successful pinch feel stiff and put the ends of the range most of a screen away; at 1.6 one step is about a 9 % spread and «۲۰۰٪» is one comfortable gesture. Both facts are covered by `test/widget/pinch_text_scale_test.dart`, including the case the arena could not do at all: a second finger landing while the list is *already scrolling*.
- A pinch settles onto one of `MessageTextScale.steps` on release, so the gesture and the settings rows always name the same size, and it writes the preference **once**, on release.

### «این شماره در مخاطبین شما نیست. هرزنامه است؟»

Shown in the conversation, on an unsaved number that has actually written to
us, and **only until it is answered**. The dismissal is persisted per
conversation (`SpamPromptStore`, a `SharedPreferences` string list capped at
500 entries, read once per process). It used to be a field on the
conversation's `State`, so it lasted exactly as long as the screen and the
banner was back on the next visit, and the next, for ever — on an inbox full of
carrier and bank senders it was the first thing on screen every single time.
Answering a question and being asked it again is the definition of nagging;
Google Messages asks once per conversation.

The banner is still withheld until `_contactResolved` (a chat opened from a
notification starts with nothing but the number, and asking «هرزنامه است؟»
about a saved contact for the first frames is the bug that guard exists for),
and reporting dismisses it too — both answers are answers.

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

### The keyboard does not come back by itself

Putting the keyboard away (back, or the keyboard's own hide key) also drops the composer's focus (`ConversationScreen.build`, the `_lastInset` guard), as Google Messages does. A field that keeps focus with no keyboard gets the keyboard back the moment any route above the conversation pops, so it rose unasked after the message menu (`showMessageActionOverlay`, which also unfocuses when no keyboard is up) and after the details page (SM A336E, 1405/07/29).

### Composer growth

**A forwarded body is APPENDED to the conversation's draft, never dropped and
never overwritten** (`ConversationScreen._restoreComposerDraft`). The saved
draft used to win outright, so forwarding a message into a conversation the user
had half-written a reply in did nothing at all — the composer kept the draft and
the forwarded text vanished with nothing on screen to say so. Overwriting is the
other way to lose text, so the forwarded body goes on its own line with the
caret after it and the draft stays above it.

The composer's field grows with the message and then scrolls inside itself,
measured against Google Messages on a real device: it stops at ~10 lines
(~320 dp), keeps the «+» / emoji buttons pinned to the bottom line, and never
changes its 28 dp corner radius.

`MessageComposer._maxLinesFor` derives `maxLines` from the space actually left
on screen (`size.height − padding.top − max(keyboard inset, emoji-panel height)
− _kReservedForChat`), clamped to `_kMaxLines`. The cap must stay a **height**,
not a plain `maxLines: 10`: with the emoji panel open a ten-line field plus the
panel is taller than the screen and the composer's `Column` overflows.

Two inputs of that height were wrong and together they are «متن میره زیر
صفحه‌کلید»:

- **The line height is the SCALED one** (`media.textScaler.scale(_kFontSize) *
  _kLineHeight`). «اندازه متن پیام» and Android's own font size multiply this
  field like everything else in the conversation, so at 200 % a line is twice
  what the nominal 16 px says and ten of them are far more than the space above
  the keyboard.
- **The keyboard inset is passed IN (`keyboardInset`), not read here.** A
  `Scaffold` removes the bottom view inset from its body — that is what
  `resizeToAvoidBottomInset` does — so a `MediaQuery` lookup from inside the
  composer reports `viewInsets.bottom == 0` with the keyboard fully up, and the
  cap never knew about the keyboard at all. `ConversationScreen._buildComposer`
  reads it from its own context, which is above the Scaffold.

**The segment counter is «۴۶/۹», drawn left-to-right.** Characters left in the
current segment over the number of SMS the message will be sent as — Google
Messages' own counter. It used to read «۴۶ باقی‌مانده · ۹ پیامک», which put a
bidi-neutral separator between Persian text and a Persian digit: the algorithm
reordered the pieces and the middle dot came out looking like a Persian zero
glued to the count, so the composer claimed «۹۰ پیامک» for a nine-part message.
Wrap it in `Directionality(ltr)`; the numbers themselves were always right.

**Selecting what has been typed** uses `selectionHeightStyle: BoxHeightStyle.max`
(the highlight covers the whole line box, so a multi-line selection is one
continuous band rather than a row of ragged strips — this field's line height is
1.45) with `selectionWidthStyle: BoxWidthStyle.tight` (`max` is exactly the "it
selects the blank part of the line too" behaviour and must not be used).

**The two notice strips are outside `PinchTextScale`.** The scaler wraps the
message list and the composer — the conversation's *text* — and nothing else.
The spam prompt and the group notice are chrome: at 200 % the prompt's `Row`
squeezed its sentence into a one-word-per-line column tall enough to push the
composer off the bottom of the screen.

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

`MessageBubble` lays its row and column out with `textDirection: TextDirection.ltr` inside an otherwise RTL conversation: **sent right, received left**, the arrangement every messenger uses, Persian ones included. Left as directional alignment, `MainAxisAlignment.end` resolved to the *left* under the screen's RTL direction, so the user's own messages ran down the left while their tail corner — a plain, non-directional `BorderRadius.only` — still pointed right. The bubble's own text does not inherit that `ltr`: a `Flex`'s `textDirection` decides how that flex lays its children out and nothing else. Its direction is the text's own (next section).

### A message reads in its own script's direction, paragraph by paragraph

An English message is left-aligned, and so is an English line inside a Persian message, while the Persian lines around it stay on the right (the mentor's report, 1405/08/05). That is what Android's own `TextView` does — every paragraph gets its own direction — and what a single Flutter `Text` cannot do: it has one base direction for all of its lines. So `LinkifiedText` cuts the body with `ScriptDirection.paragraphs` (`core/utils/script_direction.dart`) into runs of whole lines that read the same way and draws one `Text` per run, each with its own `textDirection` and `TextAlign.start`.

- **A paragraph's direction is its majority script, counted in letters** — not its first strong letter. «Hamresan یک پیام‌رسان امن است» is a Persian sentence that opens with a Latin name, and first-strong would have turned the whole line around. A tie is RTL. Digits (Persian ones included — they live in the Arabic block), harakat, punctuation and emoji count for nothing; a line with no letters at all, and a blank line, goes with the run before it, so it keeps its place and no run starts with a newline.
- **One direction is one run is one `Text`, as before** — the common case is not touched. Only a mixed body becomes a column, wrapped in `IntrinsicWidth` + `CrossAxisAlignment.stretch` so every run is as wide as the widest and its start edge is a side of the bubble, while the bubble still shrinks to its text.
- **The newline between two runs is not in either of them, and copying puts it back.** Selection inside a `SelectionArea` joins its children's text with **nothing** (`MultiSelectableSelectionContainerDelegate.getSelectedContent`), so «انتخاب همه → کپی» on a mixed message copied one glued line. The column sits in a `SelectionContainer` whose delegate (`_ParagraphsSelection`) joins with `\n`; `linkified_text_direction_test.dart` pins it, and it was checked on the SM A336E by pasting the copy back into the composer.
- The bubble's own column (`MessageBubbleBody`) takes the body's overall direction too, so a one-time-code chip or a link preview under an English message lines up on the left under the text.
- Links are matched per run. None of the patterns crosses a newline, so the result is the same as matching the whole body.

Everything that positions itself against a bubble follows the same rule and had to be swapped with it: `message_action_overlay` anchors the lifted copy's zoom (`isSent ? centerRight : centerLeft`) and hangs the action card off the bubble's own edge (`isSent ? anchor.right - width : anchor.left`), and `ScheduledBubble` — an outgoing ghost — pins its column to `ltr` too, or it sits on the opposite side from the sent messages around it.


## The caret at the end of a line, and at the start of the next

`CaretLineFix` (`core/widgets/caret_line_fix.dart`) wraps the composer's
`TextField` and puts the caret where Android's own `EditText` would have put
it, at the places Flutter's hit-testing differs from it in a wrapped Persian
paragraph. Three reports, all traced on the device (`--dart-define=CARET_TRACE=true`
prints one `[caret]` line per caret move to logcat; it is off in a store build):

- **A tap after the last word of a line lands one character too far.** «آخر یک
  کلمه توی یک خط کلیک کنی و حرف آخر رو پاک کنی، یک کاراکتر خطا داره و میره اول
  خط بعدی». The character a line ends with — the space it soft-wrapped at, or
  the newline the user typed — is not drawn, but it is still hit-tested: a tap
  in the empty run after the last word answers with the offset *after* it
  (`sel=23 aff=upstream prev=U+0020` drawn at the end of the line; `sel=8
  aff=upstream prev=U+000a` drawn at the start of the next line, for a finger on
  line 1). Either way backspace removes the break instead of the letter, the two
  words join, and the caret comes up at the start of the next line. `EditText`
  caps every line but the last at `lineEnd - 1` (`Layout.getOffsetForHorizontal`).
  So does this: a caret with `upstream` affinity right after a wrapping space is
  stepped back before it wherever it came from (`_beforeHangingSpace` — the
  offset is the same on both sides of the wrap, so the start of the next line is
  untouched), and a tap whose caret landed after a newline on the line *below*
  the finger is put at the end of the tapped line (`_correct`, candidate 2).
- **A tap at the visual start of a line lands at the end of the one above.** The
  start of an RTL line is its right edge, which is the edge of the text box; a
  fingertip straddles it and the nearest glyph can belong to the line above.
  `_correct` checks the caret against the line the finger was on and, if they
  differ, flips the affinity or re-runs the platform's hit test with the point
  pulled inside the box — line from y first, then x within it, which is
  `Layout.getLineForVertical`.
- **A dragged handle teleports across the wrap on a sideways nudge.** Offsets 74
  and 75 are adjacent, but in RTL they sit at opposite corners of two lines.
  `_clampToDraggedLine` refuses a line change while a finger is down unless the
  finger has moved half a line vertically since the caret last moved.

**What it must never do**, and the tests pin: run for typing (the text changed),
for a range selection, or for a caret moved with **no pointer** — an IME's cursor
keys, a hardware keyboard. The earlier «keep the caret on the line it was on»
rule ran for those too and *re-created* the original bug for a tap at the start
of line N+1 when the caret had been on line N (traced: `KEPT on line 0 …
platform wanted line 1`), and with the hanging-space rule in front of it would
have trapped a keyboard at the boundary. Taps go through `_correct` alone; the
drag clamp runs only while dragging; everything else is taken as the platform
gives it. `test/widget/caret_line_fix_test.dart` covers the hanging-space rule
directly (the test font wraps deterministically), the drag rules with a real
gesture, and inertness; the newline and start-of-line misplacements do not
reproduce under the test font and were verified on the device.

## Forwarding into a conversation that has a draft

`ConversationScreen.initialText` (a forward, a share, `sms:?body=`) **replaces**
the saved draft; it is not appended to it. Both other answers have shipped and
both were wrong: the draft winning outright dropped the forwarded body on the
floor with nothing on screen to say so, and concatenating them put the
half-written reply *in front of* the message being forwarded, so «ارسال» sent
the two glued together. Google Messages replaces, and the stored draft goes with
it — the composer's own listener rewrites the draft store on the same frame, so
the inbox row stops advertising text the composer no longer holds.

## The jump-to-bottom button

Anchored inside the thread's own sheet (`_ScrollToBottomButton`, a `Stack` over
the message list), **not** as `Scaffold.floatingActionButton`. The scaffold
positions its FAB against the *page*, and this screen's composer lives inside
the body rather than in a bottom bar the scaffold knows to sit above — so the
button was drawn on top of the composer, over the emoji key and next to «ارسال».
