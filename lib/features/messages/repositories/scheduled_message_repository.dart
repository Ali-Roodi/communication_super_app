import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import '../models/scheduled_message_model.dart';

/// Data access for scheduled outgoing messages (زمان‌بندی ارسال).
class ScheduledMessageRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// All schedules, soonest fire time first. Optionally filtered by [status].
  Future<List<ScheduledMessage>> getAll({ScheduleStatus? status}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.scheduledMessagesTable,
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status.value],
      orderBy: 'scheduled_at ASC',
    );
    return maps.map(ScheduledMessage.fromMap).toList();
  }

  /// Pending schedules whose fire time has arrived (`scheduled_at <= now`),
  /// soonest first — the delivery worker's work queue.
  Future<List<ScheduledMessage>> getDue(DateTime now) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.scheduledMessagesTable,
      where: 'status = ? AND scheduled_at <= ?',
      whereArgs: [ScheduleStatus.pending.value, now.millisecondsSinceEpoch],
      orderBy: 'scheduled_at ASC',
    );
    return maps.map(ScheduledMessage.fromMap).toList();
  }

  Future<ScheduledMessage?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.scheduledMessagesTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return maps.isEmpty ? null : ScheduledMessage.fromMap(maps.first);
  }

  Future<void> upsert(ScheduledMessage message) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.scheduledMessagesTable,
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> cancel(String id) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.scheduledMessagesTable,
      {'status': ScheduleStatus.cancelled.value},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.scheduledMessagesTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
