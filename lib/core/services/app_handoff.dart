/// A deliberate trip out of the app that the app itself started — the system
/// document picker today — which must not count as "leaving the app".
///
/// Both locks watch the app lifecycle: [SecureSessionGuard] closes the secure
/// section the moment the app is `paused`, and `AppLockWrapper` asks for the
/// PIN after «قفل خودکار». The system picker is another app's activity, so
/// opening it pauses this one: the key bank closed under the user while they
/// were choosing a key file, and the file they chose then went nowhere. Found
/// on the test phone, 1405/07/05.
///
/// A handoff is bounded. A pause that begins during [run] is excused only if
/// the app is back within [maxAway]; a user who walks off from the picker is
/// locked out on return exactly as before.
class AppHandoff {
  AppHandoff._();

  static const Duration maxAway = Duration(minutes: 2);

  static int _depth = 0;

  /// Whether a handoff is in progress right now.
  static bool get active => _depth > 0;

  /// Runs [action] (which opens another app's screen) as a handoff.
  static Future<T> run<T>(Future<T> Function() action) async {
    _depth++;
    try {
      return await action();
    } finally {
      _depth--;
    }
  }
}

/// What a resume ends, for an observer using [HandoffPause].
enum HandoffResume {
  /// An ordinary pause: lock as usual.
  notHandoff,

  /// A handoff that came back in time: do not lock for it.
  excused,

  /// A handoff that lasted longer than [AppHandoff.maxAway]: the lock it
  /// postponed is due now.
  overdue,
}

/// How a lifecycle observer uses [AppHandoff]: note whether a pause began
/// inside a handoff, then ask on resume what that pause was.
class HandoffPause {
  DateTime? _pausedAt;
  bool _ordinary = false;

  /// Call on `paused`/`hidden` (both may arrive for one trip out). True when
  /// the pause is part of a handoff, i.e. the caller should not lock now.
  bool onPaused([DateTime? now]) {
    if (_pausedAt == null && !_ordinary) {
      if (AppHandoff.active) {
        _pausedAt = now ?? DateTime.now();
      } else {
        _ordinary = true;
      }
    }
    return _pausedAt != null;
  }

  /// Call on `resumed`.
  HandoffResume onResumed([DateTime? now]) {
    final since = _pausedAt;
    _pausedAt = null;
    _ordinary = false;
    if (since == null) return HandoffResume.notHandoff;
    return (now ?? DateTime.now()).difference(since) > AppHandoff.maxAway
        ? HandoffResume.overdue
        : HandoffResume.excused;
  }
}
