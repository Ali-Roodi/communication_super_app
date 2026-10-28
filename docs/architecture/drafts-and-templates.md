# Drafts, categories and message templates

Part of the architecture notes for this repo. Index and the rules that apply everywhere: [`DEVELOPER_GUIDE.md`](../DEVELOPER_GUIDE.md).

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
screen as a built-in one. Rows live in `message_templates` and the
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
  chip opening a read-only copy of the fill form; that was removed by
  decision — the rebuilt text already says everything the template said, so the chip
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

