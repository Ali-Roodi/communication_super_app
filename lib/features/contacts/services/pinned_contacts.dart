import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/core/constants/app_constants.dart';

/// The contacts pinned to the top of the contacts tab (matrix row 23), by
/// device contact id, in the order they were pinned — at most
/// [AppConstants.maxPinned].
///
/// A preference, not a table: it names nothing secret, Kotlin never reads
/// it, and the address book it points into lives on the far side of the
/// platform channel anyway. A pinned contact that was deleted elsewhere is
/// dropped by [retainOnly] the next time the address book is read.
class PinnedContacts {
  PinnedContacts._();

  static final PinnedContacts instance = PinnedContacts._();

  static const _key = 'pinned_contacts';

  /// The pinned ids; empty until [load] has run.
  final ValueNotifier<List<String>> ids = ValueNotifier(const []);

  Future<void>? _loading;

  Future<void> load() => _loading ??= () async {
    final prefs = await SharedPreferences.getInstance();
    ids.value = List.unmodifiable(prefs.getStringList(_key) ?? const []);
  }();

  bool isPinned(String id) => ids.value.contains(id);

  /// Pins [toPin] after the ones already pinned. False, and nothing pinned,
  /// when that would pass [AppConstants.maxPinned].
  Future<bool> pin(Iterable<String> toPin) async {
    await load();
    final next = [...ids.value];
    for (final id in toPin) {
      if (!next.contains(id)) next.add(id);
    }
    if (next.length > AppConstants.maxPinned) return false;
    await _save(next);
    return true;
  }

  Future<void> unpin(Iterable<String> toUnpin) async {
    await load();
    final drop = toUnpin.toSet();
    final next = [
      for (final id in ids.value)
        if (!drop.contains(id)) id,
    ];
    if (next.length != ids.value.length) await _save(next);
  }

  /// Drops the pins of contacts no longer in [existing].
  Future<void> retainOnly(Set<String> existing) async {
    await load();
    if (ids.value.every(existing.contains)) return;
    await _save([
      for (final id in ids.value)
        if (existing.contains(id)) id,
    ]);
  }

  Future<void> _save(List<String> next) async {
    ids.value = List.unmodifiable(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, next);
  }

  @visibleForTesting
  void resetForTest() {
    _loading = null;
    ids.value = const [];
  }
}
