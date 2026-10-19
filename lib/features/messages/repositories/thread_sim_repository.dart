import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// The card a conversation sends on when the user chose one for it
/// («ارسال با» → «تعویض» on the conversation's details page).
///
/// Only an explicit choice is stored. A conversation without one sends on the
/// default — the app's own (Settings → «سیم‌کارت‌ها»), else the phone's — and
/// so follows that default when it changes, which is the owner's rule: "from
/// the phone's default at first, then a personal choice for each". The native
/// quick reply reads the same table (`SmsNotificationActionReceiver
/// .chosenThreadSim`) and the same default, so a reply from the shade and one
/// from the app leave on the same card.
class ThreadSimRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// In-memory mirror of the table, so a conversation opening can show its
  /// card inside `build` instead of a frame later. One small row per
  /// conversation the user ever chose a card for.
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
      // A chosen card is a convenience, never a precondition: if the table
      // cannot be read the conversation uses the default. Not cached, so a
      // later call retries.
      debugPrint('thread SIM read failed: $e');
      return const <String, int>{};
    }
  }

  /// The card chosen for this conversation, or null when none was (or it is
  /// no longer in the phone — a stored subscription id is only meaningful
  /// while that SIM is).
  Future<SimCard?> chosenFor(String threadId) async {
    final map = await _load();
    return SimService.byId(map[threadId]);
  }

  /// Whether the user chose a card for this conversation (from the mirror).
  static bool hasChoice(String threadId) =>
      SimService.byId(_cache?[threadId]) != null;

  /// Non-blocking read for `build`: the chosen card, else the default.
  static SimCard? cachedSimFor(String threadId) =>
      SimService.byId(_cache?[threadId]) ?? defaultSim;

  /// Stores the card the user chose for [threadId]; null goes back to the
  /// default.
  Future<void> choose(String threadId, SimCard? sim) async {
    if (threadId.isEmpty) return;
    final db = await _dbHelper.database;
    if (sim == null) {
      await db.delete(
        AppConstants.threadSimTable,
        where: 'thread_id = ?',
        whereArgs: [threadId],
      );
      (_cache ??= <String, int>{}).remove(threadId);
      return;
    }
    await db.insert(AppConstants.threadSimTable, {
      'thread_id': threadId,
      'subscription_id': sim.subscriptionId,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    (_cache ??= <String, int>{})[threadId] = sim.subscriptionId;
  }

  /// The card a conversation sends on: its own, else [defaultSim].
  ///
  /// Never null while a SIM is present, deliberately: the details page has to
  /// *print* which card a message will leave on and cannot print «none», so
  /// the conversation resolves a concrete card and the send uses exactly the
  /// one that was shown.
  Future<SimCard?> initialSimFor(String threadId) async =>
      await chosenFor(threadId) ?? defaultSim;

  /// The card a conversation with no choice of its own sends on: the app's
  /// default, else the phone's, else the first card in slot order.
  static SimCard? get defaultSim {
    final fallback = SimService.defaultFor(SimUse.sms);
    if (fallback != null) return fallback;
    final roster = SimService.cached;
    return roster.isEmpty ? null : roster.first;
  }

  @visibleForTesting
  static void invalidateCache() => _cache = null;
}
