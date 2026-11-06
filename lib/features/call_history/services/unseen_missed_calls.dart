import 'package:shared_preferences/shared_preferences.dart';

import '../repositories/call_log_repository.dart';

/// The number on the «اخیر» tab: missed calls since the user last had that tab
/// on screen.
///
/// A moment, not a flag on each row: `call_logs` is a mirror of the device's
/// call log, and a sync may replace a row at any time. Rows newer than the
/// moment are the unseen ones, so a missed call deleted before it was seen
/// stops counting by itself.
class UnseenMissedCalls {
  UnseenMissedCalls({CallLogRepository? repository, DateTime Function()? now})
    : _repository = repository ?? CallLogRepository(),
      _now = now ?? DateTime.now;

  final CallLogRepository _repository;
  final DateTime Function() _now;

  static const String seenAtKey = 'missed_calls_seen_at';

  /// How many missed calls the user has not seen.
  ///
  /// The first ever read has no moment to compare with. It starts counting from
  /// now, or a fresh install would show the phone's whole history of missed
  /// calls as new.
  Future<int> count() async {
    final prefs = await SharedPreferences.getInstance();
    final seenAt = prefs.getInt(seenAtKey);
    if (seenAt == null) {
      await markSeen();
      return 0;
    }
    return _repository.countMissedSince(seenAt);
  }

  /// The user has «اخیر» on screen: everything up to now is seen.
  Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(seenAtKey, _now().millisecondsSinceEpoch);
  }
}
