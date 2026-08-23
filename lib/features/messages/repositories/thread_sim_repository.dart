import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'message_repository.dart';

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

  /// thread id → the subscription its newest received message arrived on
  /// (null = looked up, nothing known). Separate from [_cache], which is the
  /// user's own choice and outranks it.
  static final Map<String, int?> _incomingCache = <String, int?>{};

  final MessageRepository _messages = MessageRepository();

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
      SimService.byId(_cache?[threadId]) ?? defaultSim;

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

  /// The SIM a conversation sends on: what it last used, falling back to the
  /// system default, falling back to the first card in slot order.
  ///
  /// That last fallback is why this never answers null while a SIM is present,
  /// and it is deliberate. The affordance that used to mean «هر بار بپرس» — an
  /// unset chip inside the composer — is gone (Google Messages has no such
  /// chip; it names the card on the conversation's details page and nowhere
  /// else). A page that has to *print* which SIM a message will leave on cannot
  /// print «none», so the conversation resolves a concrete card and the send
  /// uses exactly the one that was shown. Without the fallback, a dual-SIM
  /// phone with no system default would have shown a card and sent on whatever
  /// the platform picked, which need not be the same one.
  Future<SimCard?> initialSimFor(String threadId) async {
    final remembered = await simFor(threadId);
    if (remembered != null) return remembered;
    return await _incomingSimFor(threadId) ?? defaultSim;
  }

  /// The card the other side last reached this conversation on.
  ///
  /// Between "what this conversation last sent on" and "the phone's default
  /// SMS card" there is a third answer, and on a dual-SIM phone it is the one
  /// the user means: a message that arrived on SIM 2 is answered on SIM 2.
  /// Without this a first reply always went out on the system default, so the
  /// other side saw an answer from a number they had never written to — and
  /// the native quick-reply, which already replies on the arrival SIM,
  /// disagreed with the app's own composer.
  ///
  /// Memoized per thread (including the misses) because it is read on every
  /// conversation open and the answer only changes when a message arrives —
  /// which invalidates it explicitly.
  Future<SimCard?> _incomingSimFor(String threadId) async {
    if (_incomingCache.containsKey(threadId)) {
      return SimService.byId(_incomingCache[threadId]);
    }
    int? subscriptionId;
    try {
      subscriptionId = await _messages.lastIncomingSubscriptionId(threadId);
    } catch (e) {
      debugPrint('incoming SIM read failed: $e');
      return null;
    }
    _incomingCache[threadId] = subscriptionId;
    return SimService.byId(subscriptionId);
  }

  /// The card a conversation with no history of its own starts on.
  static SimCard? get defaultSim {
    final pinned = SimService.defaultFor(SimUse.sms);
    if (pinned != null) return pinned;
    final roster = SimService.cached;
    return roster.isEmpty ? null : roster.first;
  }

  static void invalidateCache() {
    _cache = null;
    _incomingCache.clear();
  }

  /// Drops the remembered arrival SIM of one conversation. Called when a
  /// message lands, since the newest received row is exactly what the answer
  /// is derived from.
  static void invalidateIncoming(String threadId) =>
      _incomingCache.remove(threadId);

  /// Drops every remembered arrival SIM — after a device import, which brings
  /// in received rows this app never saw land.
  static void clearIncoming() => _incomingCache.clear();
}
