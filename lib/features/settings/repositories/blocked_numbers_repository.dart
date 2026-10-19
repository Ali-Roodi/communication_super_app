import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:uuid/uuid.dart';
import '../models/blocked_number_model.dart';
import '../services/system_block_list.dart';

/// The blocked / reported numbers store.
///
/// `normalized` is the canonical thread id (`09xxxxxxxxx`) — the same key
/// `messages.thread_id` uses and the same string the native
/// `BlockedNumbers.normalizeToThreadId` produces, so a block written here is
/// found by the Dart receive path, the cold-start receiver and the in-call
/// service alike. Everything in this class goes through
/// [BlockedNumberModel.normalize]; nothing may write the column directly.
///
/// **Blocking is phone-wide.** Every block and unblock is written through to
/// Android's own list ([SystemBlockList]) as well, so the phone's dialer and
/// messages app and every other app see it, and [syncWithSystem] brings in
/// what was blocked or unblocked there. This table stays the app's own record
/// (the spam report, when it was blocked) and what the receivers read while
/// the app is not the default dialer / SMS app — the system list is not
/// readable then.
class BlockedNumbersRepository {
  BlockedNumbersRepository({SystemBlockList system = const SystemBlockList()})
    : _system = system;

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SystemBlockList _system;
  static const _uuid = Uuid();

  /// The canonical keys the system list held after the last sync — what lets
  /// [syncWithSystem] tell "unblocked in another app" from "blocked here and
  /// not written there yet".
  static const _snapshotKey = 'blocked_system_snapshot';

  Future<List<BlockedNumberModel>> getBlocked() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.blockedNumbersTable,
      orderBy: 'created_at DESC',
    );
    return maps.map(BlockedNumberModel.fromMap).toList();
  }

  /// Blocks [phoneNumber], optionally reporting it as spam, here and on the
  /// phone's own list.
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
    } else if (report && ((existing.first['is_spam'] as int?) ?? 0) == 0) {
      await db.update(
        AppConstants.blockedNumbersTable,
        {'is_spam': 1, 'reported_at': now.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    }
    await _toSystem([phoneNumber]);
    return normalized;
  }

  /// Unblocks by canonical key. Accepts a raw number too — it is normalized
  /// first, so a caller holding a display number does not have to know.
  Future<void> unblock(String normalizedOrRaw) => unblockAll([normalizedOrRaw]);

  /// Unblocks every one of [keys] — here and on the phone's own list — in one
  /// transaction («انتخاب همه» → «رفع مسدودی» on a hundred numbers).
  Future<void> unblockAll(Iterable<String> keys) async {
    final wanted = {
      for (final k in keys)
        if (BlockedNumberModel.normalize(k).isNotEmpty)
          BlockedNumberModel.normalize(k),
    };
    if (wanted.isEmpty) return;
    final db = await _dbHelper.database;
    final rows = await _rowsFor(db, wanted);
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final key in wanted) {
        batch.delete(
          AppConstants.blockedNumbersTable,
          where: 'normalized = ?',
          whereArgs: [key],
        );
      }
      await batch.commit(noResult: true);
    });
    // Every spelling we know of: the one stored here and the canonical key;
    // the platform also matches each one's E.164 form.
    await _fromSystem(
      {for (final row in rows) row.phoneNumber, ...wanted}.toList(),
      wanted,
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

  /// Reconciles this table with the phone's own list; true when this table
  /// changed. A no-op while the app may not read that list.
  ///
  /// Three-way, against the snapshot of the last sync, so each side's change
  /// wins and nothing is undone:
  /// * gone from the system since the last sync → unblocked in another app:
  ///   unblocked here too;
  /// * new on the system → blocked in another app: blocked here too;
  /// * here and not there (blocked while the app could not write the list,
  ///   or a write the provider refused) → written there now;
  /// * there, in the snapshot, and gone from here → unblocked in the app while
  ///   it could not write the list ([unblockAll] leaves such a key in the
  ///   snapshot) → taken off there now.
  Future<bool> syncWithSystem() async {
    if (!await _system.available()) return false;
    final onSystem = <String, String>{};
    for (final raw in await _system.list()) {
      final key = BlockedNumberModel.normalize(raw);
      if (key.isNotEmpty) onSystem.putIfAbsent(key, () => raw);
    }
    final prefs = await SharedPreferences.getInstance();
    final previous = (prefs.getStringList(_snapshotKey) ?? const []).toSet();
    final db = await _dbHelper.database;
    final local = {for (final row in await getBlocked()) row.normalized: row};

    final unblockedElsewhere = {
      for (final k in previous)
        if (!onSystem.containsKey(k) && local.containsKey(k)) k,
    };
    final blockedElsewhere = {
      for (final k in onSystem.keys)
        if (!previous.contains(k) && !local.containsKey(k)) k,
    };
    final unblockedHere = {
      for (final k in previous)
        if (onSystem.containsKey(k) && !local.containsKey(k)) k,
    };
    final toPush = [
      for (final e in local.entries)
        if (!onSystem.containsKey(e.key) && !previous.contains(e.key))
          e.value.phoneNumber,
    ];

    if (unblockedElsewhere.isNotEmpty || blockedElsewhere.isNotEmpty) {
      final now = DateTime.now();
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final key in unblockedElsewhere) {
          batch.delete(
            AppConstants.blockedNumbersTable,
            where: 'normalized = ?',
            whereArgs: [key],
          );
        }
        for (final key in blockedElsewhere) {
          batch.insert(
            AppConstants.blockedNumbersTable,
            BlockedNumberModel(
              id: _uuid.v4(),
              phoneNumber: onSystem[key]!,
              normalized: key,
              createdAt: now,
            ).toMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await batch.commit(noResult: true);
      });
    }
    final pushed = await _system.add(toPush);
    final pulled =
        unblockedHere.isNotEmpty &&
        await _system.remove([
          for (final k in unblockedHere) ...{onSystem[k]!, k},
        ]);
    await prefs.setStringList(_snapshotKey, [
      for (final k in onSystem.keys)
        if (!pulled || !unblockedHere.contains(k)) k,
      for (final raw in pushed) BlockedNumberModel.normalize(raw),
    ]);
    return unblockedElsewhere.isNotEmpty || blockedElsewhere.isNotEmpty;
  }

  Future<void> _toSystem(List<String> numbers) async {
    final pushed = await _system.add(numbers);
    if (pushed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final snapshot = (prefs.getStringList(_snapshotKey) ?? const []).toSet()
      ..addAll(pushed.map(BlockedNumberModel.normalize));
    await prefs.setStringList(_snapshotKey, snapshot.toList());
  }

  /// Takes [numbers] off the phone's list. When it cannot be written their
  /// [keys] stay in the snapshot, which is how [syncWithSystem] knows to take
  /// them off later rather than read them as "blocked in another app".
  Future<void> _fromSystem(List<String> numbers, Set<String> keys) async {
    if (!await _system.remove(numbers)) return;
    final prefs = await SharedPreferences.getInstance();
    final snapshot = (prefs.getStringList(_snapshotKey) ?? const []).toSet()
      ..removeAll(keys);
    await prefs.setStringList(_snapshotKey, snapshot.toList());
  }

  Future<List<BlockedNumberModel>> _rowsFor(
    Database db,
    Set<String> keys,
  ) async {
    final rows = <BlockedNumberModel>[];
    final list = keys.toList();
    // Chunked: SQLite caps bound parameters per statement.
    for (var i = 0; i < list.length; i += 400) {
      final chunk = list.sublist(i, (i + 400).clamp(0, list.length));
      final maps = await db.query(
        AppConstants.blockedNumbersTable,
        where: 'normalized IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      rows.addAll(maps.map(BlockedNumberModel.fromMap));
    }
    return rows;
  }
}
