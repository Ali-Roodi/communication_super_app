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

## 2. Watch-outs / hot paths

- **Main-isolate DB work.** Repositories run on the main isolate. Bulk reads
  (full thread list, full contacts) are fine at current caps but will degrade if
  caps are raised — keep pagination and the 500-row import cap.
- **`telephony` import payload.** The plugin marshals all matching rows through
  one MethodChannel call. The 500-cap exists to stay under the ~1 MB Binder
  transaction limit; **do not remove it** without moving import to native.
- **Contact fetch cost.** `flutter_contacts.getAllContacts()` is slow on large
  address books. It is intentionally cached per session; avoid calling it inside
  list `itemBuilder`s or per-event handlers.
- **`MemoryImage(contact.avatar!)` in list rows.** Decoding avatar bytes in a
  scrolling list (`DialerContactRow`, contact lists) can cost frames on long
  lists. Consider `ResizeImage`/thumbnail caching if avatar lists grow.
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
