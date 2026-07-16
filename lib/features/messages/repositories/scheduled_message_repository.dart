import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import '../models/scheduled_message_model.dart';

/// Data access for scheduled outgoing messages (زمان‌بندی ارسال).
///
/// Two deliverers race for the same rows: the Dart [ScheduledDeliveryService]
/// while the app is alive, and the native `ScheduledSmsWorker` when the alarm
/// fires. They coordinate through [claimDue] — a single atomic UPDATE that
/// stamps a random token onto the due rows. Only the writer whose token landed
/// reads those rows back, so a message is never sent twice.
class ScheduledMessageRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  static const _table = AppConstants.scheduledMessagesTable;

  /// All schedules, soonest fire time first. Optionally filtered by [status].
  Future<List<ScheduledMessage>> getAll({ScheduleStatus? status}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      _table,
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status.value],
      orderBy: 'scheduled_at ASC',
    );
    return maps.map(ScheduledMessage.fromMap).toList();
  }

  /// Pending schedules whose fire time has arrived and whose retry backoff (if
  /// any) has elapsed, soonest first. Read-only — see [claimDue] for delivery.
  Future<List<ScheduledMessage>> getDue(DateTime now) async {
    final db = await _dbHelper.database;
    final ms = now.millisecondsSinceEpoch;
    final maps = await db.query(
      _table,
      where:
          'status = ? AND scheduled_at <= ? '
          'AND (next_attempt_at IS NULL OR next_attempt_at <= ?)',
      whereArgs: [ScheduleStatus.pending.value, ms, ms],
      orderBy: 'scheduled_at ASC',
    );
    return maps.map(ScheduledMessage.fromMap).toList();
  }

  /// Atomically takes ownership of every due schedule by stamping [token] on it,
  /// then returns exactly the rows this caller now owns.
  ///
  /// The UPDATE is a single SQLite statement, so a competing deliverer either
  /// sees the rows as `pending` (and wins them) or as `sending` (and skips
  /// them) — never both. Returns an empty list when another deliverer got there
  /// first.
  Future<List<ScheduledMessage>> claimDue(DateTime now, String token) async {
    final db = await _dbHelper.database;
    final ms = now.millisecondsSinceEpoch;

    await releaseStaleClaims(now);

    final claimed = await db.update(
      _table,
      {
        'status': ScheduleStatus.sending.value,
        'claim_token': token,
        'claimed_at': ms,
      },
      where:
          'status = ? AND scheduled_at <= ? '
          'AND (next_attempt_at IS NULL OR next_attempt_at <= ?)',
      whereArgs: [ScheduleStatus.pending.value, ms, ms],
    );
    if (claimed == 0) return const [];

    final maps = await db.query(
      _table,
      where: 'claim_token = ? AND status = ?',
      whereArgs: [token, ScheduleStatus.sending.value],
      orderBy: 'scheduled_at ASC',
    );
    return maps.map(ScheduledMessage.fromMap).toList();
  }

  /// Returns rows stuck in `sending` past [ScheduledMessage.staleClaimTimeout]
  /// to `pending` — their owner was killed mid-send.
  Future<int> releaseStaleClaims(DateTime now) async {
    final db = await _dbHelper.database;
    final cutoff = now
        .subtract(ScheduledMessage.staleClaimTimeout)
        .millisecondsSinceEpoch;
    return db.rawUpdate(
      'UPDATE $_table SET status = ?, claim_token = NULL, claimed_at = NULL '
      'WHERE status = ? AND (claimed_at IS NULL OR claimed_at <= ?)',
      [ScheduleStatus.pending.value, ScheduleStatus.sending.value, cutoff],
    );
  }

  /// The soonest instant at which any pending schedule becomes due — what the
  /// native alarm must be armed for. Null when nothing is pending.
  Future<DateTime?> earliestDueAt() async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      'SELECT MAX(scheduled_at, COALESCE(next_attempt_at, 0)) AS due_at '
      'FROM $_table WHERE status = ? ORDER BY due_at ASC LIMIT 1',
      [ScheduleStatus.pending.value],
    );
    if (rows.isEmpty || rows.first['due_at'] == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first['due_at'] as int);
  }

  Future<ScheduledMessage?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return maps.isEmpty ? null : ScheduledMessage.fromMap(maps.first);
  }

  /// Pending schedules addressed to [threadId] (digits-normalized number),
  /// soonest first — what the conversation screen renders as ghost bubbles.
  Future<List<ScheduledMessage>> getPendingForThread(String threadId) async {
    final all = await getAll(status: ScheduleStatus.pending);
    return all.where((m) => m.threadId == threadId).toList();
  }

  /// Insert-or-replace. Always releases any claim the row held (see
  /// [ScheduledMessage.toMap]).
  Future<void> upsert(ScheduledMessage message) async {
    final db = await _dbHelper.database;
    await db.insert(
      _table,
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> cancel(String id) async {
    final db = await _dbHelper.database;
    await db.update(
      _table,
      {
        'status': ScheduleStatus.cancelled.value,
        'claim_token': null,
        'claimed_at': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  /// Moves a schedule's fire time to [at] and clears any retry backoff — the
  /// "send now" action.
  Future<void> reschedule(String id, DateTime at) async {
    final db = await _dbHelper.database;
    await db.update(
      _table,
      {
        'scheduled_at': at.millisecondsSinceEpoch,
        'status': ScheduleStatus.pending.value,
        'next_attempt_at': null,
        'attempt_count': 0,
        'claim_token': null,
        'claimed_at': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
