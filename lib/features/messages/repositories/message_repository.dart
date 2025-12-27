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

  Future<List<MessageModel>> getMessagesByThread(String threadId, {int? limit, int? offset}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.messagesTable,
      where: 'thread_id = ?',
      whereArgs: [threadId],
      orderBy: 'timestamp ASC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => MessageModel.fromMap(map)).toList();
  }

  Future<List<MessageThread>> getAllThreads({int? limit, int? offset}) async {
    final db = await _dbHelper.database;
    
    // Build the query with optional pagination
    String query = '''
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
        ) AS unread_count
      FROM ${AppConstants.messagesTable} m
      JOIN (
        SELECT thread_id, MAX(timestamp) AS max_ts
        FROM ${AppConstants.messagesTable}
        GROUP BY thread_id
      ) latest ON latest.thread_id = m.thread_id AND latest.max_ts = m.timestamp
      LEFT JOIN ${AppConstants.contactsTable} c ON c.id = m.contact_id
      ORDER BY m.timestamp DESC
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
      threads.add(MessageThread(
        threadId: map['thread_id'] as String,
        phoneNumber: map['phone_number'] as String,
        contactId: map['contact_id'] as String?,
        contactName: map['contact_name'] as String?,
        lastMessage: map['last_message'] as String,
        lastMessageTime: DateTime.fromMillisecondsSinceEpoch(
          map['last_message_time'] as int,
        ),
        unreadCount: (map['unread_count'] as int?) ?? 0,
      ));
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
}


