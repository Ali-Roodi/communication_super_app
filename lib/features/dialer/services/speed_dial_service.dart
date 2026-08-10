import 'package:flutter/foundation.dart';

import '../models/speed_dial_entry.dart';
import '../repositories/speed_dial_repository.dart';

/// The speed-dial roster, cached in memory.
///
/// A singleton with a **synchronous** read because the keypad asks for it under
/// the user's thumb: holding a key must dial, not wait for a table. The cache is
/// eight rows at most, so it is loaded once and rewritten in place on every
/// assignment.
///
/// [revision] ticks on every write, so the manage screen and anything else
/// showing the roster can rebuild without owning a bloc for eight rows.
class SpeedDialService {
  SpeedDialService._();
  static final SpeedDialService instance = SpeedDialService._();

  final SpeedDialRepository _repository = SpeedDialRepository();
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Map<int, SpeedDialEntry> _entries = const {};
  bool _loaded = false;
  Future<void>? _loading;

  /// Everything assigned, by key. Empty until [ensureLoaded] has run once.
  Map<int, SpeedDialEntry> get entries => _entries;

  /// What key [position] dials, from the cache alone. Null means "nothing
  /// assigned" *or* "not loaded yet" — callers that must tell the two apart
  /// await [ensureLoaded] first.
  SpeedDialEntry? cached(int position) => _entries[position];

  /// Loads the roster once. Concurrent callers await the same future rather
  /// than each running the query.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    final future = _load();
    _loading = future;
    try {
      await future;
    } finally {
      _loading = null;
    }
  }

  Future<void> _load() async {
    try {
      final rows = await _repository.getAll();
      _entries = {for (final row in rows) row.position: row};
      _loaded = true;
      revision.value++;
    } catch (e) {
      // A keypad that cannot read its speed dial still has to dial digits.
      debugPrint('SpeedDialService: load failed: $e');
    }
  }

  /// The entry on [position], loading the roster first when it has to.
  Future<SpeedDialEntry?> entryFor(int position) async {
    await ensureLoaded();
    return _entries[position];
  }

  Future<void> assign({
    required int position,
    required String phoneNumber,
    String? name,
    String? contactId,
  }) async {
    if (!SpeedDialEntry.isAssignable(position)) return;
    final entry = SpeedDialEntry(
      position: position,
      phoneNumber: phoneNumber,
      name: name,
      contactId: contactId,
      updatedAt: DateTime.now(),
    );
    await _repository.assign(entry);
    _entries = {..._entries, position: entry};
    _loaded = true;
    revision.value++;
  }

  Future<void> clear(int position) async {
    await _repository.clear(position);
    final next = {..._entries}..remove(position);
    _entries = next;
    revision.value++;
  }
}
