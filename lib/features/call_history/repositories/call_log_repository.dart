import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import '../models/call_log_model.dart';

class CallLogRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<void> saveCallLog(CallLogModel callLog) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.callLogsTable,
      callLog.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<CallLogModel>> getAllCallLogs({int? limit, int? offset}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.callLogsTable,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => CallLogModel.fromMap(map)).toList();
  }

  Future<List<CallLogModel>> getCallLogsByContact(String contactId, {int? limit, int? offset}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.callLogsTable,
      where: 'contact_id = ?',
      whereArgs: [contactId],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => CallLogModel.fromMap(map)).toList();
  }

  Future<void> deleteCallLog(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.callLogsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}


