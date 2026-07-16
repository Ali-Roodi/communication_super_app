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

  Future<void> deleteThread(String threadId) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.messagesTable,
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
