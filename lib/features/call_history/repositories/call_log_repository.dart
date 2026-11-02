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

  /// Persists a batch of call logs in a single DB transaction.
  ///
  /// Replaces the N individual [saveCallLog] calls that previously caused an
  /// O(N) series of separate transactions when the device call history is first
  /// imported.  On a device with 2 000+ calls this reduces write time from
  /// several seconds to under 200 ms.
  Future<void> saveCallLogsBatch(List<CallLogModel> logs) async {
    if (logs.isEmpty) return;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final log in logs) {
      batch.insert(
        AppConstants.callLogsTable,
        log.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
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

  /// The newest call of every number in the mirror, newest first — what the
  /// unified search matches against. SQLite fills the bare columns of a
  /// `MAX()` aggregate from the row holding the maximum.
  Future<List<CallLogModel>> getLatestCallPerNumber() async {
    final db = await _dbHelper.database;
    final maps = await db.rawQuery(
      'SELECT *, MAX(timestamp) AS newest FROM ${AppConstants.callLogsTable} '
      'GROUP BY phone_number ORDER BY newest DESC',
    );
    return maps.map((map) => CallLogModel.fromMap(map)).toList();
  }

  /// One number's calls, newest first, a page at a time. The column holds the
  /// number as the device logged it (`+98…`, `0098…`, `09…`), so the match is
  /// on its last ten digits; a shorter number — a service code — must match
  /// whole, or `1500` would find every number ending in it.
  Future<List<CallLogModel>> getCallLogsForNumber(
    String phone, {
    required int limit,
    int offset = 0,
  }) async {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return const [];
    const stripped =
        "REPLACE(REPLACE(REPLACE(REPLACE(phone_number, ' ', ''), '-', ''), '+', ''), '(', '')";
    final long = digits.length >= 10;
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.callLogsTable,
      where: long
          ? "$stripped LIKE ? AND LENGTH($stripped) BETWEEN 10 AND 14"
          : '$stripped = ?',
      whereArgs: [long ? '%${digits.substring(digits.length - 10)}' : digits],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => CallLogModel.fromMap(map)).toList();
  }

  /// Whether the mirror holds any row at all — the cheap "do we need a first
  /// sync?" check (`SELECT id … LIMIT 1`), so nothing reads the whole table
  /// just to find out it is non-empty.
  Future<bool> hasAnyCallLogs() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.callLogsTable,
      columns: ['id'],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Timestamp of the newest stored call, or null when the mirror is empty.
  /// The incremental sync fetches only what is newer than this.
  Future<int?> newestTimestampMs() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.callLogsTable,
      columns: ['timestamp'],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['timestamp'] as int?;
  }

  /// Ids of stored call logs at or after [sinceMs]. Scopes the mirror-sync
  /// deletion diff to the same time window the device fetch covers, so calls
  /// older than the window aren't wrongly purged.
  Future<Set<String>> getIdsSince(int sinceMs) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.callLogsTable,
      columns: ['id'],
      where: 'timestamp >= ?',
      whereArgs: [sinceMs],
    );
    return maps.map((m) => m['id'] as String).toSet();
  }

  Future<void> deleteCallLog(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.callLogsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Deletes several call logs in one statement (used when a collapsed recents
  /// group is removed as a whole).
  Future<void> deleteCallLogs(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await _dbHelper.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete(
      AppConstants.callLogsTable,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  /// Empties the local mirror. Only ever called after the device provider has
  /// actually been emptied — a local-only wipe is undone by the next sync.
  Future<void> deleteAllCallLogs() async {
    final db = await _dbHelper.database;
    await db.delete(AppConstants.callLogsTable);
  }
}
