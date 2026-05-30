import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import '../models/blocked_number_model.dart';

class BlockedNumbersRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<List<BlockedNumberModel>> getBlocked() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.blockedNumbersTable,
      orderBy: 'created_at DESC',
    );
    return maps.map(BlockedNumberModel.fromMap).toList();
  }

  Future<void> block(BlockedNumberModel number) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.blockedNumbersTable,
      number.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> unblock(String normalized) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.blockedNumbersTable,
      where: 'normalized = ?',
      whereArgs: [normalized],
    );
  }

  Future<bool> isBlocked(String normalized) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.blockedNumbersTable,
      columns: ['id'],
      where: 'normalized = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
