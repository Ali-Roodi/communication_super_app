import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:uuid/uuid.dart';
import '../models/blocked_number_model.dart';

/// The blocked / reported numbers store.
///
/// `normalized` is the canonical thread id (`09xxxxxxxxx`) — the same key
/// `messages.thread_id` uses and the same string the native
/// `BlockedNumbers.normalizeToThreadId` produces, so a block written here is
/// found by the Dart receive path, the cold-start receiver and the in-call
/// service alike. Everything in this class goes through
/// [BlockedNumberModel.normalize]; nothing may write the column directly.
class BlockedNumbersRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  static const _uuid = Uuid();

  Future<List<BlockedNumberModel>> getBlocked() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.blockedNumbersTable,
      orderBy: 'created_at DESC',
    );
    return maps.map(BlockedNumberModel.fromMap).toList();
  }

  /// Blocks [phoneNumber], optionally reporting it as spam.
  ///
  /// Idempotent, and *upgrades*: blocking a number that is already blocked and
  /// then reporting it must set the report flag rather than being swallowed by
  /// the UNIQUE constraint — «مسدود کردن و گزارش هرزنامه» on an already-blocked
  /// thread has to mean something. Reporting is never undone by a later plain
  /// block.
  ///
  /// Returns the canonical key, or null when [phoneNumber] holds no digits.
  Future<String?> block(String phoneNumber, {bool report = false}) async {
    final normalized = BlockedNumberModel.normalize(phoneNumber);
    if (normalized.isEmpty) return null;
    final db = await _dbHelper.database;
    final now = DateTime.now();

    final existing = await db.query(
      AppConstants.blockedNumbersTable,
      columns: ['id', 'is_spam'],
      where: 'normalized = ?',
      whereArgs: [normalized],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert(
        AppConstants.blockedNumbersTable,
        BlockedNumberModel(
          id: _uuid.v4(),
          phoneNumber: phoneNumber,
          normalized: normalized,
          createdAt: now,
          isSpam: report,
          reportedAt: report ? now : null,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return normalized;
    }

    if (report && ((existing.first['is_spam'] as int?) ?? 0) == 0) {
      await db.update(
        AppConstants.blockedNumbersTable,
        {'is_spam': 1, 'reported_at': now.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    }
    return normalized;
  }

  /// Unblocks by canonical key. Accepts a raw number too — it is normalized
  /// first, so a caller holding a display number does not have to know.
  Future<void> unblock(String normalizedOrRaw) async {
    final db = await _dbHelper.database;
    final normalized = BlockedNumberModel.normalize(normalizedOrRaw);
    await db.delete(
      AppConstants.blockedNumbersTable,
      where: 'normalized = ?',
      whereArgs: [normalized.isEmpty ? normalizedOrRaw : normalized],
    );
  }

  /// Clears only the spam report, leaving the block in place («این هرزنامه
  /// نیست» on a number the user still does not want to hear from).
  Future<void> clearReport(String normalizedOrRaw) async {
    final db = await _dbHelper.database;
    final normalized = BlockedNumberModel.normalize(normalizedOrRaw);
    await db.update(
      AppConstants.blockedNumbersTable,
      {'is_spam': 0, 'reported_at': null},
      where: 'normalized = ?',
      whereArgs: [normalized.isEmpty ? normalizedOrRaw : normalized],
    );
  }

  Future<bool> isBlocked(String phoneNumber) async {
    final normalized = BlockedNumberModel.normalize(phoneNumber);
    if (normalized.isEmpty) return false;
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

  /// Every blocked key, for the callers that test many numbers at once (the
  /// inbox splitting blocked threads out of the conversation list). One query
  /// instead of one per thread.
  Future<Set<String>> blockedKeys() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.blockedNumbersTable,
      columns: ['normalized'],
    );
    return {for (final row in rows) row['normalized'] as String};
  }
}
