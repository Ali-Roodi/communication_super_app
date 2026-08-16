import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import '../models/message_model.dart';
import '../models/template_wire.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import '../models/message_search_query.dart';

class MessageRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<String> createMessage(MessageModel message) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.messagesTable,
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return message.id;
  }

  Future<List<MessageModel>> getMessagesByThread(
    String threadId, {
    int? limit,
    int? offset,
    bool orderDesc = false,
  }) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.messagesTable,
      where: 'thread_id = ? AND is_deleted = 0',
      whereArgs: [threadId],
      orderBy: orderDesc ? 'timestamp DESC' : 'timestamp ASC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => MessageModel.fromMap(map)).toList();
  }

  // ── «ستاره‌دار» ─────────────────────────────────────────────────────────

  /// Stars or unstars one message. Local-only metadata — nothing is written to
  /// the device SMS provider.
  Future<void> setStarred(String messageId, bool starred) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messagesTable,
      {'is_starred': starred ? 1 : 0},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Every starred message, newest first, across all threads.
  Future<List<MessageModel>> getStarredMessages({int limit = 200}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.messagesTable,
      where: 'is_starred = 1 AND is_deleted = 0',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return maps.map((map) => MessageModel.fromMap(map)).toList();
  }

  /// The inbox rows, newest-first with pinned threads on top.
  ///
  /// [restrictToThreadIds] narrows the whole query to the given threads and is
  /// how [searchThreads] renders its hits: the search decides *which* threads
  /// match, this decides what a thread row looks like, so the two can never
  /// drift apart (the last-message pick and the unread count below are subtle
  /// enough that a second copy of this query would be a bug waiting to happen).
  /// An empty list matches nothing and returns immediately — `IN ()` is a syntax
  /// error in SQLite.
  Future<List<MessageThread>> getAllThreads({
    int? limit,
    int? offset,
    bool archived = false,
    List<String>? restrictToThreadIds,
    bool includeBlocked = false,
  }) async {
    if (restrictToThreadIds != null && restrictToThreadIds.isEmpty) {
      return const [];
    }
    final db = await _dbHelper.database;

    // archived == false  -> exclude threads present in archived_threads
    // archived == true   -> only threads present in archived_threads
    final archiveClause = archived
        ? 'm.thread_id IN (SELECT thread_id FROM ${AppConstants.archivedThreadsTable})'
        : 'm.thread_id NOT IN (SELECT thread_id FROM ${AppConstants.archivedThreadsTable})';

    // A blocked conversation leaves every list this returns — inbox, archive and
    // search alike — and lives in «هرزنامه و مسدودشده» instead. This is the
    // visible half of blocking, and its absence is what made blocking read as a
    // no-op: the messages stopped arriving, but the thread the user blocked sat
    // in the inbox exactly as before, so nothing looked like it had happened.
    //
    // `blocked_numbers.normalized` is the canonical thread id (see
    // `BlockedNumberModel`), so this is a plain indexed subquery on the same key
    // — no join on formatting, and no per-thread work.
    final blockClause = includeBlocked
        ? ''
        : ' AND m.thread_id NOT IN '
              '(SELECT normalized FROM ${AppConstants.blockedNumbersTable})';

    final restrictClause = restrictToThreadIds == null
        ? ''
        : ' AND m.thread_id IN (${List.filled(restrictToThreadIds.length, '?').join(',')})';

    // Pinned threads (only relevant in the non-archived inbox) float to the top.
    //
    // Paging happens in the `page` CTE, on nothing but (thread_id, last_ts,
    // is_pinned) — the expensive per-thread work (picking the last message row,
    // counting unread) then runs on the ≤ `limit` rows that survived, not on
    // every thread in the table. The flat version of this query ran a
    // correlated rowid subquery *per message row* of the whole table before
    // LIMIT applied, which is what made scrolling the inbox stall for seconds
    // on a full phone.
    //
    // The "last message" row is still picked with a correlated rowid subquery
    // rather than a `MAX(timestamp)` join: when two messages in a thread share
    // the same timestamp (multipart SMS, or two messages delivered in the same
    // millisecond) a MAX join matches *both* rows and the thread shows up twice
    // in the inbox. Matching on rowid guarantees exactly one row per thread.
    final pageLimit = limit == null
        ? ''
        : ' LIMIT $limit${offset != null ? ' OFFSET $offset' : ''}';

    final query =
        '''
      WITH latest AS (
        SELECT m.thread_id AS thread_id, MAX(m.timestamp) AS last_ts
        FROM ${AppConstants.messagesTable} m
        WHERE m.is_deleted = 0 AND $archiveClause$blockClause$restrictClause
        GROUP BY m.thread_id
      ),
      page AS (
        SELECT
          l.thread_id AS thread_id,
          l.last_ts AS last_ts,
          (p.thread_id IS NOT NULL) AS is_pinned
        FROM latest l
        LEFT JOIN ${AppConstants.pinnedThreadsTable} p ON p.thread_id = l.thread_id
        ORDER BY is_pinned DESC, l.last_ts DESC$pageLimit
      )
      SELECT
        page.thread_id AS thread_id,
        page.is_pinned AS is_pinned,
        m.phone_number,
        m.contact_id,
        c.name AS contact_name,
        m.body AS last_message,
        m.timestamp AS last_message_time,
        (
          -- Counts unread rows of ANY type on purpose: every sent row is
          -- inserted with is_read = 1, so the only sent row that can be
          -- unread is one `markThreadAsUnread` flagged on a thread with no
          -- received message. Filtering on type here is what made the
          -- "mark unread" swipe silently do nothing on those threads.
          SELECT COUNT(*) FROM ${AppConstants.messagesTable} mi
          WHERE mi.thread_id = page.thread_id
            AND mi.is_read = 0 AND mi.is_deleted = 0
        ) AS unread_count
      FROM page
      JOIN ${AppConstants.messagesTable} m ON m.rowid = (
        SELECT ml.rowid FROM ${AppConstants.messagesTable} ml
        WHERE ml.thread_id = page.thread_id AND ml.is_deleted = 0
        ORDER BY ml.timestamp DESC, ml.rowid DESC
        LIMIT 1
      )
      LEFT JOIN ${AppConstants.contactsTable} c ON c.id = m.contact_id
      ORDER BY page.is_pinned DESC, page.last_ts DESC
    ''';

    final maps = await db.rawQuery(query, restrictToThreadIds);

    final threads = <MessageThread>[];
    for (var map in maps) {
      threads.add(
        MessageThread(
          threadId: map['thread_id'] as String,
          phoneNumber: map['phone_number'] as String,
          contactId: map['contact_id'] as String?,
          contactName: map['contact_name'] as String?,
          lastMessage: map['last_message'] as String,
          lastMessageTime: DateTime.fromMillisecondsSinceEpoch(
            map['last_message_time'] as int,
          ),
          unreadCount: (map['unread_count'] as int?) ?? 0,
          isPinned: ((map['is_pinned'] as int?) ?? 0) == 1,
        ),
      );
    }
    return threads;
  }

  // ── Search ──────────────────────────────────────────────────────────────
  //
  // Two entry points, one engine: [searchMessages] returns the matching
  // messages (the «پیام‌ها» section of the unified search) and [searchThreads]
  // returns the conversations they belong to (the inbox search field). Both go
  // through [MessageSearchQuery], whose header documents the prefilter and why
  // it cannot miss a row `SearchText` would match.
  //
  // Nothing here filters on `type`: **a sent message is as much a search hit as
  // a received one.** The old inbox "search" filtered the paged-in thread list
  // by `thread.lastMessage`, i.e. by the single newest message of each loaded
  // thread — usually the incoming one, which is exactly why it looked like the
  // app only ever searched received messages.

  /// Rows pulled out of SQLite per prefilter page. Big enough that a selective
  /// query answers in one round trip, small enough that a one-letter query does
  /// not marshal thousands of bodies to find the first screenful.
  static const int _kSearchPageSize = 400;

  /// Hard cap on prefiltered rows examined in Dart for one search.
  ///
  /// This is the price of having no FTS index: a query whose prefilter is not
  /// selective (a single letter, or a query that folds away to nothing) degrades
  /// to "search the most recent [_kMaxPrefilteredRows] messages" instead of
  /// walking a full mailbox on the UI isolate. Anything more specific than one
  /// letter never comes near the cap.
  static const int _kMaxPrefilteredRows = 4000;

  /// Cap on the conversations examined for a *number* match in [searchThreads].
  /// One row per conversation, so this is the whole address book's worth of
  /// threads on any real phone.
  static const int _kMaxScannedThreads = 4000;

  /// Rows folded into the FTS index per [syncSearchIndex] call.
  ///
  /// The backfill of an existing mailbox runs through this in batches instead of
  /// one long transaction: it happens behind a painted screen, and a single
  /// 50,000-row fold would hold the isolate for seconds.
  static const int _kIndexBatch = 500;

  /// Cap on rows taken from an FTS match before the authoritative filter.
  ///
  /// The index is selective enough that a real query returns far fewer; this
  /// only stops a pathological three-character needle from marshalling a whole
  /// mailbox.
  static const int _kMaxFtsRows = 3000;

  /// Cap on thread ids handed back to [getAllThreads] as bind variables — well
  /// under SQLite's 999-variable limit, and far more search hits than a list
  /// can usefully show.
  static const int _kMaxSearchThreads = 200;

  // ── Search index maintenance ──────────────────────────────────────────────

  /// Whether the FTS index may be trusted for a search *right now*.
  ///
  /// Two conditions, and the second is the subtle one: the index must exist on
  /// this device (see `DatabaseHelper.messageSearchFtsReady`) **and** it must
  /// have no backlog. A half-filled index is worse than no index — it answers
  /// confidently and silently omits the rows it has not folded yet — so while
  /// anything is unindexed every search takes the scan path instead. Existing
  /// mailboxes therefore behave exactly as before until the backfill finishes,
  /// and then get faster.
  Future<bool> searchIndexReady() async {
    if (!DatabaseHelper.messageSearchFtsReady) return false;
    final db = await _dbHelper.database;
    final pending = await db.rawQuery(
      'SELECT EXISTS(SELECT 1 FROM ${AppConstants.messagesTable} '
      'WHERE search_indexed = 0) AS pending',
    );
    return (pending.first['pending'] as int? ?? 1) == 0;
  }

  /// Folds up to [_kIndexBatch] unindexed message bodies into the FTS index.
  ///
  /// Returns the number of rows indexed, so a caller can loop until it drains.
  /// Safe to call at any time and from anywhere: it is idempotent, it is bounded,
  /// and it is the *only* writer of the index.
  ///
  /// Two details that matter:
  /// * The indexed text is the **displayed** body, folded — a template message is
  ///   stored as its compact payload (see [TemplateWire]), so indexing the raw
  ///   column would make it findable only by its wire header.
  /// * Each row is deleted from the index before being inserted. SQLite reuses
  ///   the rowid of a hard-deleted message, and without the delete a stale entry
  ///   would attach itself to whatever message inherits that rowid — the index
  ///   would answer with text from a message that no longer exists.
  Future<int> syncSearchIndex() async {
    if (!DatabaseHelper.messageSearchFtsReady) return 0;
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.messagesTable,
      columns: ['rowid', 'body'],
      where: 'search_indexed = 0',
      limit: _kIndexBatch,
    );
    if (rows.isEmpty) return 0;

    final batch = db.batch();
    for (final row in rows) {
      final rowid = row['rowid'] as int;
      final folded = SearchText.foldTight(
        TemplateWire.displayText(row['body'] as String),
      );
      batch.delete(
        AppConstants.messageSearchTable,
        where: 'rowid = ?',
        whereArgs: [rowid],
      );
      batch.insert(AppConstants.messageSearchTable, {
        'rowid': rowid,
        'folded': folded,
      });
      batch.rawUpdate(
        'UPDATE ${AppConstants.messagesTable} '
        'SET search_indexed = 1 WHERE rowid = ?',
        [rowid],
      );
    }
    await batch.commit(noResult: true);
    return rows.length;
  }

  /// Messages whose **body** matches [query], newest first, sent and received
  /// alike.
  ///
  /// Paged: [offset]/[limit] count *authoritative* hits, so paging is stable
  /// (the underlying order is fixed) even though the SQL prefilter is scanned in
  /// larger pages behind the scenes. [threadId] restricts the search to one
  /// conversation.
  Future<List<MessageModel>> searchMessages(
    String query, {
    int limit = 50,
    int offset = 0,
    String? threadId,
  }) async {
    final q = MessageSearchQuery(query);
    if (q.isEmpty || limit <= 0) return const [];

    final hits = <MessageModel>[];
    final wanted = offset + limit;
    await _scanBodies(
      q,
      threadId: threadId,
      columns: null,
      onRow: (row) {
        hits.add(MessageModel.fromMap(row));
        return hits.length < wanted;
      },
    );
    if (hits.length <= offset) return const [];
    return hits.sublist(offset, hits.length < wanted ? hits.length : wanted);
  }

  /// Threads matching [query] by phone number or by the body of **any** message
  /// in them — not just the newest one, which is all a filter over the loaded
  /// inbox list can see.
  ///
  /// Contact **names** are matched by the caller: the names the inbox paints
  /// come from the device address book, not from any column here (the local
  /// `contacts` table is legacy and nothing writes to it). Pass the thread ids
  /// already matched by name as [alsoThreadIds] and they come back in the same
  /// pinned-then-newest order as the rest, so the caller renders one list.
  Future<List<MessageThread>> searchThreads(
    String query, {
    int limit = 60,
    bool archived = false,
    Set<String> alsoThreadIds = const {},
  }) async {
    final q = MessageSearchQuery(query);
    if (q.isEmpty) return const [];

    // The caller's name matches lead, so truncating below never throws away a
    // hit the user can see a reason for.
    final ids = <String>{...alsoThreadIds};

    // Body hits arrive newest-first, so `ids` stays in a sensible order.
    await _scanBodies(
      q,
      columns: const ['thread_id', 'body'],
      onRow: (row) {
        ids.add(row['thread_id'] as String);
        return ids.length < _kMaxSearchThreads;
      },
    );

    if (q.hasDigits && ids.length < _kMaxSearchThreads) {
      ids.addAll(await _threadIdsMatchingNumber(q));
    }
    if (ids.isEmpty) return const [];

    final capped = ids.length <= _kMaxSearchThreads
        ? ids.toList()
        : ids.take(_kMaxSearchThreads).toList();
    return getAllThreads(
      limit: limit,
      archived: archived,
      restrictToThreadIds: capped,
    );
  }

  /// Walks the prefiltered rows newest-first, handing each one that survives
  /// [MessageSearchQuery.matchesBody] to [onRow]; stops when [onRow] returns
  /// false or the scan budget is spent.
  ///
  /// The scan is paged rather than one big `LIMIT _kMaxPrefilteredRows` read so
  /// that the common (selective) query marshals one page and stops — the cap is
  /// a safety net, not the normal cost.
  Future<void> _scanBodies(
    MessageSearchQuery q, {
    required bool Function(Map<String, Object?> row) onRow,
    List<String>? columns,
    String? threadId,
  }) async {
    final db = await _dbHelper.database;

    // Indexed path. Only taken when the index exists, has no backlog, and the
    // needle is long enough for a trigram to speak about it; otherwise the scan
    // below answers, with identical results.
    if (q.canUseFts && await searchIndexReady()) {
      final select = columns == null
          ? 'm.*'
          : columns.map((c) => 'm.$c').join(', ');
      final args = <Object?>[q.ftsMatch];
      var where = 'm.is_deleted = 0';
      if (threadId != null) {
        where += ' AND m.thread_id = ?';
        args.add(threadId);
      }
      // Paged, exactly like the scan below, and for the same reason: a needle as
      // common as «سلام» matches thousands of rows, and fetching + sorting all of
      // them before Dart filters made the *indexed* path slower than the scan it
      // replaced (measured: 94 ms against 7 ms on a 50k-message mailbox, because
      // the scan stops as soon as the caller has its screenful). Paging restores
      // the early-out and keeps the rare-needle win.
      var scanned = 0;
      var sqlOffset = 0;
      while (scanned < _kMaxFtsRows) {
        final page = await db.rawQuery('''
          SELECT $select FROM ${AppConstants.messageSearchTable} s
          JOIN ${AppConstants.messagesTable} m ON m.rowid = s.rowid
          WHERE s.folded MATCH ? AND $where
          ORDER BY m.timestamp DESC, m.rowid DESC
          LIMIT $_kSearchPageSize OFFSET $sqlOffset
        ''', args);
        if (page.isEmpty) return;
        scanned += page.length;
        sqlOffset += page.length;
        for (final row in page) {
          if (!q.matchesBody(TemplateWire.displayText(row['body'] as String))) {
            continue;
          }
          if (!onRow(row)) return;
        }
        if (page.length < _kSearchPageSize) return;
      }
      return;
    }

    final clauses = <String>['is_deleted = 0'];
    final args = <Object?>[];
    if (threadId != null) {
      clauses.add('thread_id = ?');
      args.add(threadId);
    }
    final prefilter = q.bodyWhere;
    if (prefilter != null) {
      // A compact template payload («[#T1:mtg:1]علی|جلسه هفتگی|…») carries the
      // answers but none of the template's prose, so the prefilter would reject
      // a row whose *rendered* text plainly matches — searching «جلسه» would
      // miss the meeting invitation it wrote. Payload rows are a small, cheaply
      // identified subset (`[` is not a LIKE wildcard in SQLite), so they are
      // admitted unconditionally and settled in Dart by the same authoritative
      // matcher, against `TemplateWire.displayText`.
      clauses.add('(($prefilter) OR body LIKE \'${TemplateWire.sigil}%\')');
      args.addAll(q.bodyArgs);
    }
    final where = clauses.join(' AND ');

    var scanned = 0;
    var sqlOffset = 0;
    while (scanned < _kMaxPrefilteredRows) {
      final page = await db.query(
        AppConstants.messagesTable,
        columns: columns,
        where: where,
        whereArgs: args,
        // Deterministic total order (timestamps collide on multipart SMS), so
        // OFFSET paging below cannot skip or repeat a row. Backed by
        // `idx_messages_search` (is_deleted, timestamp DESC) — the filter first
        // so tombstones are seeked past rather than read and rejected, then the
        // ordering, so there is no sort.
        orderBy: 'timestamp DESC, rowid DESC',
        limit: _kSearchPageSize,
        offset: sqlOffset,
      );
      if (page.isEmpty) return;
      scanned += page.length;
      sqlOffset += page.length;
      for (final row in page) {
        // `displayText` is the identity for ordinary bodies (one `startsWith`),
        // so this costs nothing on the rows that are not template payloads.
        if (!q.matchesBody(TemplateWire.displayText(row['body'] as String))) {
          continue;
        }
        if (!onRow(row)) return;
      }
      if (page.length < _kSearchPageSize) return;
    }
  }

  /// Threads whose phone number matches the digits of the query.
  ///
  /// Matching runs in Dart because only [PhoneQuery] knows that `+98912…`,
  /// `0912…` and `912…` are the same number, and a `thread_id LIKE` prefilter
  /// provably *can* miss: a query of `89121` matches the stored digits of
  /// `+989121234567` in the middle, while the thread id is the national
  /// `09121234567`, which does not contain it. So the candidate list is read
  /// instead — one row per conversation (not per message), bounded by
  /// [_kMaxScannedThreads] and only read for a query that has digits in it.
  Future<Set<String>> _threadIdsMatchingNumber(MessageSearchQuery q) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT thread_id, MIN(phone_number) AS phone_number
      FROM ${AppConstants.messagesTable}
      WHERE is_deleted = 0
      GROUP BY thread_id
      ORDER BY MAX(timestamp) DESC
      LIMIT ?
      ''',
      [_kMaxScannedThreads],
    );
    // MIN(phone_number) is an arbitrary pick on purpose: every row of a thread
    // carries the same number in some formatting, and PhoneQuery normalizes.
    final ids = <String>{};
    for (final row in rows) {
      final threadId = row['thread_id'] as String;
      final phone = (row['phone_number'] as String?) ?? threadId;
      if (q.phone.contains(phone) || q.phone.contains(threadId)) {
        ids.add(threadId);
      }
    }
    return ids;
  }

  /// Fetches full rows for the given message ids (used to build the provider
  /// delete specs before a global delete).
  Future<List<MessageModel>> getMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await _dbHelper.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final maps = await db.query(
      AppConstants.messagesTable,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    return maps.map(MessageModel.fromMap).toList();
  }

  // ── Device mirror-sync ────────────────────────────────────────────────────

  /// One-time backfill: rows imported before the v11 migration used the device
  /// provider row id as their `id`, so a numeric id IS the provider id.
  Future<void> backfillDeviceSmsIds() async {
    final db = await _dbHelper.database;
    await db.rawUpdate('''
      UPDATE ${AppConstants.messagesTable}
      SET device_sms_id = CAST(id AS INTEGER)
      WHERE device_sms_id IS NULL AND id GLOB '[0-9]*' AND id NOT GLOB '*[^0-9]*'
    ''');
  }

  /// Reconciles a batch of device-provider rows into the local store.
  ///
  /// Per row (all inside one transaction):
  /// 1. Already known by `device_sms_id` → skip.
  /// 2. Exact content match (unique-index key) → adopt: set `device_sms_id`.
  /// 3. Fuzzy match (same thread/body/type within [fuzzyWindow]) → adopt.
  ///    Needed because a live-received row stores the SMS-PDU timestamp while
  ///    the provider stores the device receive time — the two differ by
  ///    seconds, which defeats the exact unique index.
  /// 4. No match → insert as a new message.
  /// What a matched local row learns from its provider twin: the provider row
  /// id always, and the SIM **only when the provider actually recorded one** —
  /// writing null over a subscription the local row already knew (a message we
  /// sent ourselves) would erase good data on every sync.
  Map<String, Object?> _linkValues(int deviceId, int? subscriptionId) => {
    'device_sms_id': deviceId,
    if (subscriptionId != null) 'subscription_id': subscriptionId,
  };

  Future<void> reconcileDeviceRows(
    List<MessageModel> deviceRows, {
    Duration fuzzyWindow = const Duration(minutes: 2),
  }) async {
    if (deviceRows.isEmpty) return;
    final db = await _dbHelper.database;
    final windowMs = fuzzyWindow.inMilliseconds;

    // Step 1 in bulk: in the steady state EVERY row of the batch is already
    // known, and asking that one row at a time meant a query per provider row
    // on every sync. One `IN (…)` read answers it for the whole batch, so a
    // resume sync that has nothing new to do now touches the DB twice.
    final knownDeviceIds = await _knownDeviceSmsIds([
      for (final row in deviceRows)
        if (row.deviceSmsId != null) row.deviceSmsId!,
    ]);
    final pending = [
      for (final row in deviceRows)
        if (row.deviceSmsId != null &&
            !knownDeviceIds.contains(row.deviceSmsId))
          row,
    ];
    if (pending.isEmpty) return;

    await db.transaction((txn) async {
      for (final row in pending) {
        final deviceId = row.deviceSmsId!;

        // 2. Exact content match (same key as the dedup unique index).
        final exact = await txn.query(
          AppConstants.messagesTable,
          columns: ['id'],
          where:
              'phone_number = ? AND body = ? AND timestamp = ? AND type = ? '
              'AND device_sms_id IS NULL',
          whereArgs: [
            row.phoneNumber,
            row.body,
            row.timestamp.millisecondsSinceEpoch,
            row.type.name,
          ],
          limit: 1,
        );
        if (exact.isNotEmpty) {
          await txn.update(
            AppConstants.messagesTable,
            _linkValues(deviceId, row.subscriptionId),
            where: 'id = ?',
            whereArgs: [exact.first['id']],
          );
          continue;
        }

        // 3. Fuzzy match: PDU timestamp vs provider receive time skew.
        final ts = row.timestamp.millisecondsSinceEpoch;
        final fuzzy = await txn.query(
          AppConstants.messagesTable,
          columns: ['id'],
          where:
              'thread_id = ? AND body = ? AND type = ? '
              'AND device_sms_id IS NULL AND timestamp BETWEEN ? AND ?',
          whereArgs: [
            row.threadId,
            row.body,
            row.type.name,
            ts - windowMs,
            ts + windowMs,
          ],
          limit: 1,
        );
        if (fuzzy.isNotEmpty) {
          await txn.update(
            AppConstants.messagesTable,
            _linkValues(deviceId, row.subscriptionId),
            where: 'id = ?',
            whereArgs: [fuzzy.first['id']],
          );
          continue;
        }

        // 4. New message from the device.
        await txn.insert(
          AppConstants.messagesTable,
          row.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  /// Which of [deviceIds] the local store already carries.
  ///
  /// Public because the mirror-sync asks it *before* reading any content: the
  /// import is a diff of the provider's id list against this, so a steady-state
  /// sync fetches nothing at all and a first run fetches exactly the mailbox.
  /// Deliberately ignores `is_deleted` — a tombstone still owns its
  /// `device_sms_id`, and re-importing a message the user deleted is the bug
  /// that flag exists to prevent.
  Future<Set<int>> knownDeviceSmsIds(List<int> deviceIds) =>
      _knownDeviceSmsIds(deviceIds);

  /// Which of [deviceIds] the local store already carries, read in chunks that
  /// stay under SQLite's bound-variable limit.
  Future<Set<int>> _knownDeviceSmsIds(List<int> deviceIds) async {
    if (deviceIds.isEmpty) return const {};
    final db = await _dbHelper.database;
    final known = <int>{};
    for (var i = 0; i < deviceIds.length; i += 500) {
      final end = i + 500 > deviceIds.length ? deviceIds.length : i + 500;
      final chunk = deviceIds.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        AppConstants.messagesTable,
        columns: ['device_sms_id'],
        where: 'device_sms_id IN ($placeholders)',
        whereArgs: chunk,
      );
      for (final row in rows) {
        known.add((row['device_sms_id'] as num).toInt());
      }
    }
    return known;
  }

  /// Hard-deletes local rows whose provider row no longer exists — the message
  /// was deleted on the device, so it must disappear here too. Rows without a
  /// `device_sms_id` are never touched (failed sends, provider-less rows).
  ///
  /// Returns the number of rows removed.
  /// The diff is computed **inside SQLite**, via a temp table of the provider
  /// ids, instead of pulling every local row across the platform channel and
  /// subtracting in Dart. On a full phone that read marshalled tens of
  /// thousands of rows on every sync — including the silent resume sync — and
  /// that channel traffic is what jammed the UI thread mid-scroll.
  Future<int> removeRowsMissingFromDevice(Set<int> deviceIds) async {
    final db = await _dbHelper.database;
    return db.transaction<int>((txn) async {
      await txn.execute(
        'CREATE TEMP TABLE IF NOT EXISTS _device_sms_ids (id INTEGER PRIMARY KEY)',
      );
      await txn.execute('DELETE FROM _device_sms_ids');
      final batch = txn.batch();
      for (final id in deviceIds) {
        batch.insert('_device_sms_ids', {
          'id': id,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
      final deleted = await txn.rawDelete('''
        DELETE FROM ${AppConstants.messagesTable}
        WHERE device_sms_id IS NOT NULL
          AND device_sms_id NOT IN (SELECT id FROM _device_sms_ids)
      ''');
      await txn.execute('DROP TABLE IF EXISTS _device_sms_ids');
      return deleted;
    });
  }

  Future<void> updateMessageStatus(
    String messageId,
    MessageStatus status,
  ) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messagesTable,
      {'status': status.name},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Soft-deletes a whole conversation: the rows stay as tombstones (hidden by
  /// the `is_deleted = 0` filter on every query) so `reconcileDeviceRows` keeps
  /// recognising their `device_sms_id` and never re-imports them.
  Future<void> softDeleteThread(String threadId) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messagesTable,
      {'is_deleted': 1},
      where: 'thread_id = ?',
      whereArgs: [threadId],
    );
  }

  /// Clears the unread flag on every row of the thread — including the sent row
  /// [markThreadAsUnread] may have flagged on a thread with no received message.
  /// Filtering on `type = 'received'` here would leave such a thread bold for
  /// ever, with no way back.
  Future<void> markThreadAsRead(String threadId) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messagesTable,
      {'is_read': 1},
      where: 'thread_id = ? AND is_read = 0',
      whereArgs: [threadId],
    );
  }

  /// Marks a thread unread again (swipe / selection bar).
  ///
  /// Flags the received messages, but falls back to the newest row of any type
  /// when the thread has none that still counts: a conversation the user only
  /// ever *sent* to, or whose received messages were all deleted, has nothing
  /// to flag — the swipe used to run and leave the row un-bolded, because
  /// `unread_count` only ever sees non-deleted rows.
  Future<void> markThreadAsUnread(String threadId) async {
    final db = await _dbHelper.database;
    final flagged = await db.update(
      AppConstants.messagesTable,
      {'is_read': 0},
      where: 'thread_id = ? AND type = ? AND is_deleted = 0',
      whereArgs: [threadId, 'received'],
    );
    if (flagged > 0) return;
    await db.rawUpdate(
      '''
      UPDATE ${AppConstants.messagesTable}
      SET is_read = 0
      WHERE rowid = (
        SELECT rowid FROM ${AppConstants.messagesTable}
        WHERE thread_id = ? AND is_deleted = 0
        ORDER BY timestamp DESC, rowid DESC
        LIMIT 1
      )
      ''',
      [threadId],
    );
  }

  Future<void> softDeleteMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final db = await _dbHelper.database;
    final placeholders = List.filled(messageIds.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE ${AppConstants.messagesTable} SET is_deleted = 1 WHERE id IN ($placeholders)',
      messageIds,
    );
  }

  // ── Archive ────────────────────────────────────────────────────────────
  Future<void> archiveThread(String threadId) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.archivedThreadsTable,
      {
        'thread_id': threadId,
        'archived_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> unarchiveThread(String threadId) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.archivedThreadsTable,
      where: 'thread_id = ?',
      whereArgs: [threadId],
    );
  }

  // ── Pin ────────────────────────────────────────────────────────────────
  Future<void> pinThread(String threadId) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.pinnedThreadsTable,
      {
        'thread_id': threadId,
        'pinned_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> unpinThread(String threadId) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.pinnedThreadsTable,
      where: 'thread_id = ?',
      whereArgs: [threadId],
    );
  }
}
