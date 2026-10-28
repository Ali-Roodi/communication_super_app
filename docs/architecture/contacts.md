# Contacts: extras, merging, labels, photo, naming and ordering

Part of the architecture notes for this repo. Index and the rules that apply everywhere: [`DEVELOPER_GUIDE.md`](../DEVELOPER_GUIDE.md).

**Reading the address book never asks for the permission** (`ContactRepository._hasPermission`, a `permission_handler` status check). It used to call `FlutterContacts.requestPermission`, and since global blocs read contacts before `PermissionGate` is built, every fresh install put the system dialog over the PIN offer (SM A336E and POCO X3, 1405/07/29). A read without the grant returns an empty list and is **not cached**: the gate grants it a moment later, and a cached empty book stayed empty until the next restart.

**Contact extras / «برنامه‌های متصل»:** `ContactExtrasHandler.kt` reads the third-party Data rows on a contact (rows whose MIME type is outside the standard set). Two things this depends on, both easy to break: the manifest `<queries>` entries for `android.accounts.AccountAuthenticator` and `VIEW`+`vnd.android.cursor.item/*` (targetSdk 30+ package visibility otherwise hides the authenticator, `packageForAccountType` returns null and the whole section renders empty), and resolving the row's action to a **concrete component** before launching — messengers register several activity-aliases per custom MIME type, so an implicit intent (even with `setPackage`) pops an "Open with" sheet listing the same app twice.

**Merging duplicates is `AggregationExceptions`, not a rewrite.** `ContactLinkHandler.kt` (+ `ContactLinkService`) writes `TYPE_KEEP_TOGETHER` over every pair of the raw contacts behind the selected contacts — `flutter_contacts` cannot do this, and "write one contact and delete the others" is a different, lossy thing: nothing is copied, nothing is deleted, each account keeps its own row, and `unlink` (`TYPE_KEEP_SEPARATE`, so the provider's matcher cannot silently re-aggregate) takes it apart again. The row is written with `newUpdate` — the provider upserts on the (raw1, raw2) key and an insert throws.

- Three entry points: the contacts selection bar («ادغام», hidden when the selection includes a SIM contact — an ADN record has no ContactsContract row to aggregate), `DuplicateContactsScreen` (union-find over *shared number* **or** *same folded name*; both rules are needed, and grouping has to be transitive), and «جدا کردن مخاطب‌های پیوندشده» on the contact page, shown only when `rawContactCount > 1`.
- The linked id is **not** necessarily one of the inputs — the provider re-aggregates and picks — so callers refresh instead of assuming.
- **The merge asks whose name and photo survive** (`showMergeContactsDialog` → `link(ids, primaryContactId:)`). Aggregation alone does not decide that: the provider picks a display name of its own, so merging «علی» with a row saved as a number silently renamed the person. `ContactLinkHandler` captures the chosen contact's raw ids *before* aggregating and then sets `IS_SUPER_PRIMARY`/`IS_PRIMARY` on its StructuredName and Photo rows. Both entry points (selection bar, `DuplicateContactsScreen`) go through the dialog; it defaults to the longest name.

**Labels («برچسب‌ها») are editable, and the provider's group list is not the user's.** Every account carries its own «Family»/«Coworkers», and a Google contact also sits in «My Contacts» and «Starred in Android». `ContactGroupsService` therefore exposes a `ContactLabel` = *name* + every group id carrying it: one row on screen, reads and writes fanned out, internal names hidden (`isInternal` / `visibleNames`). Without that the labels screen listed «Coworkers» three times.

**Memberships are written natively, NOT through `flutter_contacts`** (`ContactGroupsHandler.kt`, channel `…/contact_groups`). A `Groups` row and a `RawContacts` row each belong to an account and a `GroupMembership` is only valid when **the two match**; the plugin's `insertGroup` writes a TITLE and no account at all, so every label made through it was account-less, every membership written against it meaningless, and the label came back empty — which is the whole of the "I save a contact into a label and the label is empty" report. `applyLabels` / `addToLabel` / `removeFromLabel` / `memberIds` / `createLabel` replace it; `AddEditContactScreen` saves the contact with a plain `update()`/`insert()` and then calls `applyLabels`.

- **`AddEditContactScreen._save` must clear `contact.groups` before writing, and that is a crash fix.** `flutter_contacts` builds one `GroupMembership` INSERT per entry of `contact.groups` on *every* update — unconditionally — while deleting the existing membership rows only when `withGroups: true`, which this call is not. So each save **doubled** the contact's membership rows (1 → 2 → 4 …), and around the tenth save the batch crossed `ContactsProvider2`'s ceiling of 500 operations: `applyBatch` threw «Too many content provider operations between yield points», the plugin runs it on a bare `CoroutineScope(Dispatchers.IO)` with **no try/catch**, and an uncaught exception on a background thread kills the process. That is the whole of «I update a contact photo, press save, and the app throws me out» — nothing Dart could catch, and the photo was never the cause. Verified on the device: one contact had reached 512 identical rows for one group.
- **Any batch this app hands the contacts provider is chunked below 500** — `ContactGroupsHandler.applyInChunks` and the bulk contact delete in `ContactsListScreen`. A batch that crosses the ceiling writes nothing at all, and through the plugin it takes the process with it.
- `applyLabels` **drops duplicate membership rows** (same raw contact, same group) as it goes: another app (or the plugin, given groups) can leave them, and this is the only repair path.

- **The account a new label goes into is ranked, not just "the busiest"** (`busiestAccount` + `accountRank`). A messenger that mirrors the whole address book into its own sync account outnumbers the phone's real store — measured on the test device, 298 rows in `ir.eitaa.messenger` against 158 in `vnd.sec.contact.phone` — so plain "busiest" created every label inside a **read-only copy** its adapter may wipe. Rank comes from `ContentResolver.getSyncAdapterTypes()` (no permission needed): no contacts adapter registered = a device-local store and the best home (2), an adapter that `supportsUploading` = a real cloud account (1), a download-only adapter = a mirror (0). SIM accounts are excluded — an ADN record has no `Groups` row to belong to.
- **A label lives in as many accounts as it has members.** `applyLabels` writes each membership against a raw contact **in the group's own account**, creating the group in that account when it is not there yet, and `memberIds` matches by *title* across accounts. So one «Family» on screen is routinely several `Groups` rows underneath, and that is correct.
- `groupFor` prefers an id the contact already carries, so saving does not move the tag to another account.
- The «برچسب‌ها» row sits in the editor's main form, **not** behind «فیلدهای بیشتر» — buried there nobody found it, which is most of why labels went unused.
- A label page («برچسب‌ها» → tap) is where a label is *used*: «افزودن مخاطب» (contact picker → `addToLabel`) and «پیامک گروهی» (→ the group conversation for its members, named after the label) live in its app bar, and deleting a label asks first — the membership rows go with it and re-creating the name brings nobody back.

**The hidden phonebook «دفترچه مخفی» is not part of the address book** — it lives only in the secure section's `secure.db` (`lib/features/hidden/`), and «از دفترچه تلفن گوشی» there offers to delete the contact it was filled from. See `editions.md`.

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

**Number → contact matching is exact first, then the last seven digits.** The
exact key is `PhoneNormalizer.toThreadId`; the fallback is
`PhoneNormalizer.toTailKey`, and it exists because the app resolves the same
caller two different ways. A *ringing* call is named natively through
`ContactsContract.PhoneLookup`, which compares only the trailing digits
(Android's `min_match`, 7); «اخیر», the inbox and every avatar resolved it in
Dart through exact equality on a normalizer with rules only for Iranian mobile
shapes. So a contact saved without its area code, or in any shape those rules
do not cover, **showed its name while the phone rang and its bare number in the
call list a second later** — «انگار که چنین مخاطبی ذخیره نشده».

Three indices carry the fallback and all three build it the same way, in the
same pass as the exact one: `ContactRepository._tailIndex`,
`CallLogService._tailIndex` and `ContactNameCache._tailMemo` (derived on read,
never stored — the table keeps only the canonical key). **A tail two different
contacts share is stored as `null`**, so an ambiguous number resolves to nobody
rather than to whichever contact was indexed first: this is strictly more
conservative than the platform lookup it is catching up with, and a wrong name
is worse than a number. Numbers with fewer than seven digits (short codes,
service addresses) have no tail and are never matched loosely.

**A rename reaches every surface, because there is one signal.** `ContactRepository.revision` is a `ValueNotifier` bumped by `invalidateCache()` — i.e. by every mutation, ours or the phone's Contacts app (`MainNavigation._refreshDeviceContacts` invalidates rather than dispatching, so both sources arrive the same way). `MainNavigation` listens and fans out `RefreshContacts` + `RefreshContactNames` + `RefreshCallLogContactNames`; the conversation header re-resolves its own title (`_resolveContactName(force: true)`, which must also be able to go back to *no* name — the contact may have been deleted, and the spam prompt hangs off that answer); the details page and each `_FavoriteCard` re-read their own contact. Before this, renaming from the chat header updated the contacts tab and nothing else: the header behind it, «اخیر» and «مورد علاقه» all kept the old name until the app was restarted.

- It is bumped by `invalidateCache()` and **not** by a `forceRefresh` read — that read is how the listeners themselves reload, so bumping there would loop.
- **Starring is per *person*, not per number.** The picker used to ask «کدام شماره؟» for a contact with several; that made adding a favourite a two-step decision about a question that only matters at the moment of *calling* — and it is asked there, by the long-press sheet and by `placeCall`. The row is keyed on the contact's primary number and `_FavoriteCard` resolves the live contact from it, so the name, the photo and the numbers all stay current.
  - **…and the long-press sheet is where that question actually gets asked** (`_FavoriteCard._chooseNumber` → `pickContactNumber`), for «تماس», «ارسال پیامک» **and** the «تماس با سیم …» rows (`simCallRows(resolveNumber:)`). It did not, which made the promise above false: the sheet silently used the number the contact happened to be starred from, so somebody with a mobile and a work line could only ever be reached on the first — from the one screen built for reaching them quickly. Nothing is asked when there is no choice (one number, or a number belonging to no saved contact), and the stored number is used then, because that is the one the user starred.
- **«مورد علاقه» stores a denormalized name** (`favorites.name`, the name the number had when it was starred), so it can never be corrected by a bloc refresh. `_FavoriteCard` resolves the live contact and prefers it, keeping the stored copy only as the fallback for a number that belongs to no contact.
- **`call_logs` has no contact-name column at all** — it is overlaid per page by `CallLogService.resolveContactNames` — so `RefreshCallLogContactNames` re-reads the paged-in rows rather than patching them: a name has to be able to *disappear* when its contact is deleted, and an overlay can only add.

The static contact cache carries a **generation counter**: `invalidateCache()` / `forceRefresh` bump it, and a read that started before the bump refuses to publish its (pre-write) snapshot. Saving a contact invalidates the cache while the `FlutterContacts.addListener` refresh already has a read in flight — without the guard that stale snapshot won, and a contact added from a call log stayed missing from the list *and* the search until the next app start.

**An edit is visible on the page you edited from.** Two halves, and both were missing: `DeviceContactDetailScreen` derives its title from the contact it *re-read* after the editor pops (through `ContactNameStyle.format`, so it obeys «قالب نام»), and `LazyContactAvatar` carries a `static ValueNotifier<int> generation` bumped inside `invalidateCache()` — every mounted avatar listens and reloads its own bytes. Without the second one the name updated and the photo did not, which looks worse than neither. Before this, a rename or a new photo only appeared after leaving the contacts screen and coming back.

### Contact name format & ordering

«قالب نام» and «مرتب‌سازی بر اساس» are applied **where the ContactModel is built** (`ContactRepository.getDeviceContacts`), not where a row is drawn: the name that comes out is what the list, the search, the dialer suggestions, the call-log resolution and the fast-scroll index all see, so they cannot disagree. `ContactNameStyle` (`core/utils/`) is the static mirror of the two settings — same pattern as `DateFormatter.calendar`, for the same reason (a plain repository has no `BuildContext`).

- The formatted name and the order are baked into the cache, so a setting change has to force a re-read: `ContactNameStyle.apply` sets the statics **then** emits on `onChanged`, and `ContactBloc` listens and dispatches `RefreshContacts` — the same shape as its `SimService.onChanged` subscription. Emitting before the statics are set would re-cache the old names.
- `ContactModel` keeps `firstName`/`lastName` beside the rendered `name`, and `sortName` is what the address book is **ordered and bucketed** by: under «نام خانوادگی» a row has to appear under the family name's section letter, which is not the letter its displayed name starts with. Both parts are null for a SIM (ADN) record or a one-word/company row, and every path falls back to `name`.
- **The list is sorted by us, not by the provider** (`ContactRepository._sorted`). Three things need that and none come free: family-name ordering is not an order `ContactsContract` was asked for, the SIM cards' contacts are *appended* after the phone's (they sat in a clump at the bottom), and the fast-scroll bar jumps to an offset accumulated from the section ranks — a list ordered against those ranks lands the jump on the wrong name.
- **`PersianCollator` (`core/utils/persian_alphabet.dart`) is the ordering.** `String.compareTo` is UTF-16 order and the Persian alphabet is not in UTF-16 order — پ چ ژ ک گ all sit outside the ب…ی run — so a naive sort scatters them. The key maps each `SearchText.fold`ed character onto its rank, prefixed by the section rank so list order and index bar can never diverge, and is built **once per contact** (decorate–sort–undecorate); building it inside the comparator folds every name O(log n) times over a whole address book.
- The alphabet, the letter aliases and `sectionLetterFor` live in that same file because `ContactsListScreen` and the repository must use one table.


## The add/edit form's phone and email rows

Every row is `[icon rail 24] [gap 16] [field, Expanded] [type] [✕]`, and the two
trailing controls are **deliberately undersized** (`CompactLabelDropdown`,
`RemoveFieldButton` in `screens/widgets/contact_form_fields.dart`).

A stock `DropdownButton` sizes itself to its widest menu item («محل کار») and
adds a 24 dp arrow plus its own padding; a stock `IconButton` is a 48 dp square.
Together they took ~116 dp out of the ~288 dp a 360 dp phone has for the row,
which left the **number** field — the only field on the row anyone types into —
narrower than the label floating over it. That is the reported «فیلد اینپوت
شماره موبایل خیلی کوچیکه».

Now: the dropdown is capped at 62 dp with a `labelMedium` value, a 16 dp arrow,
`isDense`, and a `selectedItemBuilder` that ellipsises the *closed* label while
the open menu still lists every type at full size; the ✕ is a 32 dp target with
`padding: EdgeInsets.zero`. The field keeps the rest. Do not restore either
control to its default size — this row is measured, not styled.

## The contact page's numbers

* **No «ارسال با» card.** It used to list one row per number naming the SIM that
  number's *conversation* sends on — a property of a conversation answered on a
  page about a person, and it sat **above** the numbers, so the first thing the
  page showed was a SIM table instead of the phone numbers. Google Contacts has
  no such section. The choice still exists where it belongs: the conversation's
  own details page, plus a long-press on «تماس» here to dial out on the other
  card.

* **The default number is the platform's**, `ContactsContract.Data.IS_SUPER_PRIMARY`
  — the same flag Google Contacts writes and every other app reads when it has
  to pick ONE number for a contact (a launcher shortcut, a share target). A
  preference of our own would have been invisible to all of them.
  `ContactExtrasHandler.setDefaultPhone` sets it (and `IS_PRIMARY` with it: the
  first is "preferred for the aggregate", the second "preferred within this raw
  contact", and only the pair answers correctly for a contact linked across two
  accounts), clearing the flag from the contact's other numbers in one batch.

  `clearDefaultPhone` takes it off every number, and it is **not optional**:
  without it, setting a default is a one-way door — the flag can be moved from
  number to number but never removed. It is also not only ours to begin with:
  the platform writes this flag too (on the test device a number acquired one
  without the app touching it), so a contact can arrive already showing a
  «پیش‌فرض» the user never chose, and there has to be a way off it. Both paths
  go through one `writeDefaultPhone` batch, so the contact never has two
  defaults — or none — even for an instant.

  **Numbers are matched on their last nine digits, never as strings.** The
  provider stores what the user typed («0935-979-4645», «+98 935…») and the UI
  shows it formatted; a literal comparison found nothing and the menu item
  silently did nothing. `PHONE_NUMBERS_EQUAL` is not used for the reason it is
  avoided everywhere else here — it is locale-dependent and disagrees with
  `PhoneNormalizer` on Iranian numbers.

* **Long-press on a number opens a named menu** (تماس · ارسال پیامک · تنظیم
  به‌عنوان شماره پیش‌فرض *or* حذف شماره پیش‌فرض · تماس با سیم‌کارت دیگر · کپی
  شماره). The set/clear pair is mutually exclusive and reads off that row: «تنظیم»
  only when the contact has more than one number and this is not already the
  default, «حذف» whenever this row **is** the default — including a
  single-number contact, because the flag can have been put there by something
  else. It replaces a
  long-press that silently meant "dial on the other SIM" and existed only on a
  dual-SIM phone: an unlabelled gesture with a device-dependent result.

* **`pickContactNumber` takes `entries: List<PickablePhone>`**, so the "which
  number?" sheet shows each number under the label it was saved with and floats
  the default to the top with a «پیش‌فرض» chip. The bare `numbers:` form is
  still there for callers that only hold strings.

* **A default number is an ANSWER, not a hint — the sheet does not open at
  all.** When exactly one entry is `isDefault`, `pickContactNumber` returns it
  without asking, which is what Google Contacts does: it asks which line only
  while the contact has none. It used to show the sheet regardless, with the
  default merely sorted first and wearing its chip, so a user who had pinned a
  line was asked the same question on every تماس and every پیام and the setting
  read as decorative. Two rows flagged default (which `IS_SUPER_PRIMARY` should
  never produce) falls back to asking rather than guessing.

  `pickContactNumberFor(contactId:, numbers:, title:)` is the form for callers
  that hold a *contact* rather than prepared rows — «موردعلاقه‌ها», «جستجو»,
  «گفتگوی جدید». It reads `ContactExtrasService.getDefaultPhone` at gesture
  time (one platform call, never in a build, never for a single-number contact)
  so those surfaces agree with the contact page instead of each re-asking a
  question the user has already answered.
