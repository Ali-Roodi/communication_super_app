import 'package:sqflite/sqflite.dart';

import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';

import '../models/speed_dial_entry.dart';

/// SQLite access for the speed-dial table (v21).
class SpeedDialRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// Every assignment, ordered by key.
  Future<List<SpeedDialEntry>> getAll() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.speedDialTable,
      orderBy: 'position ASC',
    );
    return rows.map(SpeedDialEntry.fromMap).toList();
  }

  /// Assigns [entry] to its key, replacing whatever was there.
  ///
  /// REPLACE, not INSERT: `position` is the primary key precisely because a
  /// digit holds one number, and "assign" on a taken key is a re-assignment,
  /// not an error to report.
  Future<void> assign(SpeedDialEntry entry) async {
    if (!SpeedDialEntry.isAssignable(entry.position)) return;
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.speedDialTable,
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clear(int position) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.speedDialTable,
      where: 'position = ?',
      whereArgs: [position],
    );
  }
}
