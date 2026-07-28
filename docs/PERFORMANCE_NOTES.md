# PERFORMANCE NOTES

Performance-relevant behaviours already in the code, plus guidance for keeping
the app smooth. Most hot paths involve **large device data sets** (thousands of
SMS / call-log / contact rows) on the main isolate.

## 1. Existing optimizations (do not regress)

| Area | Technique | Where |
|------|-----------|-------|
| Call-log mapping | Maps thousands of raw entries on a **background `Isolate`** (`Isolate.run`), enriches with contacts on main | `CallLogService.getCallLogs` |
| SMS import | **Capped at 500 inbox + 500 sent**; written in **batches of 100** with `Future.delayed(Duration.zero)` yields between batches | `SmsService.importDeviceMessages` |
| SMS import dedup | Batch inserts use `ConflictAlgorithm.ignore` against a unique content index — no read-before-write | `MessageRepository` / `DatabaseHelper` |
| Call-log persistence | Single **batch transaction** instead of N inserts (previously caused multi-second freezes) | `CallLogService` → `CallLogRepository.saveCallLogsBatch` |
| Contact-name resolution | phone→name map built **once per session** and reused for every `LoadThreads` | `MessageBloc._cachedPhoneToName` |
| Call-log cache | In-memory `static _cache` + concurrent-load guard | `CallLogService` |
| Tab switching | `_FadeIndexedStack` keeps **all tabs mounted** (scroll position + loaded data survive); 150 ms fade | `MainNavigation` |
| Unread badge | `BlocBuilder.buildWhen` rebuilds only when the unread **total** changes | `MainNavigation` |
| Dialer filtering | Keypad input **debounced 300 ms** before filtering contacts | `DialerBloc._onNumberPressed` |
| DB indexes | `messages(thread_id)`, `messages(timestamp DESC)`, `messages(is_read)`, `call_logs(timestamp DESC)`, unique content index | `DatabaseHelper._createDB` |
| Thread / message lists | Paginated (`limit`/`offset`, 50/page) with infinite scroll | `MessageBloc` `LoadMore*` |
| Recents load | **Never reads the whole `call_logs` table.** `ensureSynced()` only checks `hasAnyCallLogs()` (`LIMIT 1`) and syncs if empty; rows come from the paginated `getAllCallLogs(limit:50)` | `CallLogService` / `CallLogBloc` |
| Call-log name resolution | Normalized phone→contact index **memoized** against the contact-cache identity instead of rebuilt per page | `CallLogService._contactIndex` |
| Contact avatars | Lazy per-id fetch, bounded LRU (200) + negative cache + in-flight dedup; the bulk contact cache holds **no** photo bytes | `LazyContactAvatar` / `ContactRepository` |
| Data-driven lists | Virtualized: `SliverGroupedList` (lazy twin of `GroupedList`) for dialer suggestions, unified search, starred, schedules | `core/widgets/google_list.dart` |
| Contact filtering | Contacts-tab search debounced 200 ms; filter/grouping results memoized on (query, source identity) | `ContactsListScreen`, `ContactSelectorScreen` |

## 1b. Resume / sync budget (the alt-tab stall)

Returning to the app used to run, on **every** resume: a full 365-day call-log
re-read *and* re-write (twice — `MainNavigation` and the recents screen each
fired their own), a full address-book re-read (twice — `ContactBloc` and
`MessageBloc.RefreshContactNames`), plus a thumbnail-cache wipe. Rules now:

| Trigger | What may run |
|---------|--------------|
| Resume | delta call-log sync (rows newer than the newest stored one), throttled SMS mirror-sync (2 min), address-book re-read **at most every 10 min** |
| Address book actually changed (`FlutterContacts` listener) | immediate contact refresh + thumbnail-cache clear |
| Call-log ContentObserver (call ended, row deleted) | delta sync; deletion diff at most every 5 min |
| Pull-to-refresh / explicit refresh | everything, unthrottled |

- Deletion detection reads **ids only**, natively (`callLogIdsSince`) — never
  full rows.
- First call-log import walks the window in 30-day slices with a yield between
  them and accumulates nothing.
- `MessageRepository.reconcileDeviceRows` resolves "already known" for the whole
  batch with one `IN (…)` query instead of one query per provider row.
- Heavy device reads (contacts, SMS provider, call log) are serialized through
  `DeviceSyncQueue` so a cold start never holds three large channel payloads at
  once — that peak is what killed the app on low-memory phones.
- `ContactRepository.getContactByPhoneNumber` is an indexed map lookup, not a
  scan: its callers are loops (per starred message, per favourite, per incoming
  SMS).

## 2. Watch-outs / hot paths

- **Main-isolate DB work.** Repositories run on the main isolate. Bulk reads
  (full thread list, full contacts) are fine at current caps but will degrade if
  caps are raised — keep pagination and the 500-row import cap.
- **`another_telephony` import payload.** The plugin marshals all matching rows through
  one MethodChannel call. The 500-cap exists to stay under the ~1 MB Binder
  transaction limit; **do not remove it** without moving import to native.
- **Contact fetch cost.** `flutter_contacts.getAllContacts()` is slow on large
  address books. It is intentionally cached per session; avoid calling it inside
  list `itemBuilder`s or per-event handlers.
- **Never put a data-driven row count inside `GroupedList` / `ListView(children:)`.**
  Both build every row eagerly, and each contact row fires its own avatar
  lookup — a one-digit dial query matching the whole address book then costs
  thousands of widgets *and* thousands of platform-channel reads. Use
  `SliverGroupedList` / `ListView.builder`. `GroupedList` stays for fixed-size
  groups (settings rows, sheets).
- **`setState(() {})` on every keystroke** in the conversation composer (to
  update the SMS segment counter) rebuilds the composer subtree per character.
  Cheap today; if the composer grows, scope it to a `ValueListenableBuilder`.

## 3. Build-time / rebuild discipline

- Prefer `const` constructors (the lints encourage this) — many leaf widgets are
  already `const`.
- Use `buildWhen`/`listenWhen` on `BlocBuilder`/`BlocListener` for anything that
  rebuilds inside a list or the nav shell.
- Keep extracted leaf widgets **stateless and `const`-constructible** where
  possible so the framework can skip subtree rebuilds.

## 4. How to profile

```bash
flutter run --profile        # then open DevTools → Performance / CPU
```
- Watch for jank when first opening **Recents** (call-log map+persist) and
  **Messages** (first-run import).
- Check the **raster** thread for avatar-heavy lists.

## 5. Quick wins available (see REFACTORING_ROADMAP)

- Fix K1 normalization so contact enrichment hits the cache instead of falling
  through (fewer "unknown" rows, no perf cost).
- Thumbnail-cache contact avatars for list rows.
