import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// Which SIM each conversation sends on.
///
/// Google Messages remembers this **per conversation**, and that is the whole
/// point: a number that reached you on the work SIM is answered from the work
/// SIM even when the other card is the system default. A single global
/// "selected SIM" would be wrong for every conversation but the last one.
///
/// The value is written when a message actually goes out, not when the picker
/// closes, so it always reflects what was really used.
class ThreadSimRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// In-memory mirror of the table, so a conversation opening can seed its
  /// composer chip inside `build` instead of a frame later. The table is one
  /// small row per conversation the user has ever sent from.
  static Map<String, int>? _cache;

  Future<Map<String, int>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final db = await _dbHelper.database;
      final rows = await db.query(
        AppConstants.threadSimTable,
        columns: ['thread_id', 'subscription_id'],
      );
      final map = <String, int>{
        for (final row in rows)
          row['thread_id'] as String: (row['subscription_id'] as num).toInt(),
      };
      _cache = map;
      return map;
    } catch (e) {
      // A remembered SIM is a convenience, never a precondition: if the table
      // cannot be read the composer falls back to the system default, which
      // is exactly what a conversation with no history does anyway. Not
      // cached, so a later call retries.
      debugPrint('thread SIM read failed: $e');
      return const <String, int>{};
    }
  }

  /// The SIM this conversation last sent on, or null when it never has.
  ///
  /// A card that has since been removed answers null too — a stored
  /// subscription id is only meaningful while that SIM is in the phone.
  Future<SimCard?> simFor(String threadId) async {
    final map = await _load();
    return SimService.byId(map[threadId]);
  }

  /// Non-blocking read for `build`. Null means "not known *yet*" as well as
  /// "never chosen", so callers fall back to the system default either way —
  /// which is the same answer the async path gives on a first visit.
  static SimCard? cachedSimFor(String threadId) =>
      SimService.byId(_cache?[threadId]);

  /// Records the SIM a message actually went out on.
  Future<void> remember(String threadId, int? subscriptionId) async {
    if (threadId.isEmpty) return;
    if (subscriptionId == null ||
        subscriptionId == SimCard.invalidSubscriptionId) {
      return;
    }
    try {
      final db = await _dbHelper.database;
      await db.insert(AppConstants.threadSimTable, {
        'thread_id': threadId,
        'subscription_id': subscriptionId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      // Losing the memory of which SIM a conversation used must never fail
      // the send that just succeeded.
      debugPrint('thread SIM write failed: $e');
      return;
    }
    (_cache ??= <String, int>{})[threadId] = subscriptionId;
  }

  /// The SIM a composer should start on: what this conversation last used,
  /// falling back to the system default, falling back to the only SIM.
  ///
  /// Null on a dual-SIM phone with no default pinned means «هر بار بپرس» — the
  /// composer shows an unset chip rather than silently choosing.
  Future<SimCard?> initialSimFor(String threadId) async {
    return await simFor(threadId) ?? SimService.defaultFor(SimUse.sms);
  }

  static void invalidateCache() => _cache = null;
}
