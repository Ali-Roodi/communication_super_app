import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import '../models/message_model.dart';

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

  Future<void> createMessagesBatch(List<MessageModel> messages) async {
    if (messages.isEmpty) return;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final message in messages) {
      // IGNORE on conflict: the unique index on (phone_number, body, timestamp,
      // type) ensures a message that was already inserted by the live
      // BroadcastReceiver (with a UUID id) is not duplicated by the device
      // inbox import (which uses the device SMS id as the id value).
      batch.insert(
        AppConstants.messagesTable,
        message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
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

  Future<List<MessageThread>> getAllThreads({
    int? limit,
    int? offset,
    bool archived = false,
  }) async {
    final db = await _dbHelper.database;

    // archived == false  -> exclude threads present in archived_threads
    // archived == true   -> only threads present in archived_threads
    final archiveClause = archived
        ? 'm.thread_id IN (SELECT thread_id FROM ${AppConstants.archivedThreadsTable})'
        : 'm.thread_id NOT IN (SELECT thread_id FROM ${AppConstants.archivedThreadsTable})';

    // Pinned threads (only relevant in the non-archived inbox) float to the top.
    //
    // The "last message" row is picked with a correlated rowid subquery rather
    // than a `MAX(timestamp)` join: when two messages in a thread share the same
    // timestamp (multipart SMS, or two messages delivered in the same
    // millisecond) a MAX join matches *both* rows and the thread shows up twice
    // in the inbox. Matching on rowid guarantees exactly one row per thread.
    String query =
        '''
      SELECT
        m.thread_id,
        m.phone_number,
        m.contact_id,
        c.name AS contact_name,
        m.body AS last_message,
        m.timestamp AS last_message_time,
        (
          SELECT COUNT(*) FROM ${AppConstants.messagesTable} mi
          WHERE mi.thread_id = m.thread_id AND mi.type = 'received'
            AND mi.is_read = 0 AND mi.is_deleted = 0
        ) AS unread_count,
        p.thread_id AS pinned_id,
        p.pinned_at AS pinned_at
      FROM ${AppConstants.messagesTable} m
      LEFT JOIN ${AppConstants.contactsTable} c ON c.id = m.contact_id
      LEFT JOIN ${AppConstants.pinnedThreadsTable} p ON p.thread_id = m.thread_id
      WHERE m.is_deleted = 0 AND $archiveClause
        AND m.rowid = (
          SELECT ml.rowid FROM ${AppConstants.messagesTable} ml
          WHERE ml.thread_id = m.thread_id AND ml.is_deleted = 0
          ORDER BY ml.timestamp DESC, ml.rowid DESC
          LIMIT 1
        )
      ORDER BY (pinned_id IS NOT NULL) DESC, m.timestamp DESC
    ''';

    if (limit != null) {
      query += ' LIMIT $limit';
      if (offset != null) {
        query += ' OFFSET $offset';
      }
    }

    final maps = await db.rawQuery(query);

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
          isPinned: map['pinned_id'] != null,
        ),
      );
    }
    return threads;
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
        if (row.deviceSmsId != null && !knownDeviceIds.contains(row.deviceSmsId))
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
            {'device_sms_id': deviceId},
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
          whereArgs: [row.threadId, row.body, row.type.name, ts - windowMs, ts + windowMs],
          limit: 1,
        );
        if (fuzzy.isNotEmpty) {
          await txn.update(
            AppConstants.messagesTable,
            {'device_sms_id': deviceId},
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
  Future<int> removeRowsMissingFromDevice(Set<int> deviceIds) async {
    final db = await _dbHelper.database;
    final local = await db.query(
      AppConstants.messagesTable,
      columns: ['id', 'device_sms_id'],
      where: 'device_sms_id IS NOT NULL',
    );
    final staleIds = <String>[
      for (final row in local)
        if (!deviceIds.contains((row['device_sms_id'] as num).toInt()))
          row['id'] as String,
    ];
    if (staleIds.isEmpty) return 0;
    var deleted = 0;
    // Chunked to stay under SQLite's bound-variable limit.
    for (var i = 0; i < staleIds.length; i += 500) {
      final chunk = staleIds.sublist(
        i,
        i + 500 > staleIds.length ? staleIds.length : i + 500,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      deleted += await db.delete(
        AppConstants.messagesTable,
        where: 'id IN ($placeholders)',
        whereArgs: chunk,
      );
    }
    return deleted;
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

  Future<void> deleteMessage(String messageId) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.messagesTable,
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Hard-deletes every row of a thread. Only for local-only data (tests,
  /// legacy paths) — the user-facing delete is [softDeleteThread], because a
  /// hard delete throws away the `device_sms_id` tombstones the mirror-sync
  /// needs and the whole conversation comes back on the next sync.
  Future<void> deleteThread(String threadId) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.messagesTable,
      where: 'thread_id = ?',
      whereArgs: [threadId],
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

  Future<void> markThreadAsRead(String threadId) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messagesTable,
      {'is_read': 1},
      where: 'thread_id = ? AND type = ? AND is_read = 0',
      whereArgs: [threadId, 'received'],
    );
  }

  /// Marks all received messages in a thread as unread again.
  Future<void> markThreadAsUnread(String threadId) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messagesTable,
      {'is_read': 0},
      where: 'thread_id = ? AND type = ?',
      whereArgs: [threadId, 'received'],
    );
  }

  /// Soft-deletes a single message (kept in DB so the dedup unique index row
  /// survives, but hidden from every query via is_deleted = 0 filters).
  Future<void> softDeleteMessage(String messageId) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messagesTable,
      {'is_deleted': 1},
      where: 'id = ?',
      whereArgs: [messageId],
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

  Future<bool> isThreadArchived(String threadId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.archivedThreadsTable,
      where: 'thread_id = ?',
      whereArgs: [threadId],
      limit: 1,
    );
    return rows.isNotEmpty;
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

  Future<bool> isThreadPinned(String threadId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.pinnedThreadsTable,
      where: 'thread_id = ?',
      whereArgs: [threadId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
