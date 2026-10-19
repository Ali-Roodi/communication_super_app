import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';

/// Slows down guessing a PIN.
///
/// Five free attempts, then a lockout that doubles with each further failure
/// (30 s, 1 min, 2 min … capped at 30 min). A success clears it. There are two
/// budgets, never shared: the **app PIN**'s (every app-PIN check goes through
/// [AuthRepository.validatePin]) and the **secure section PIN**'s
/// ([PinAttemptLimiter.secureSection], used by `SecureSessionBloc` before the
/// vault's PBKDF2 ever runs) — so locking yourself out of one never locks you
/// out of the other, and guesses at one never count against the other.
///
/// Persisted, so killing the app does not reset the count. It is a speed bump
/// for someone holding the phone, not a defense against root — the secure
/// section's Keystore binding is what stands against that.
class PinAttemptLimiter {
  PinAttemptLimiter({DateTime Function()? now}) : this._('pin', now);

  /// The secure section PIN's own budget.
  PinAttemptLimiter.secureSection({DateTime Function()? now})
    : this._('secure_pin', now);

  PinAttemptLimiter._(String prefix, DateTime Function()? now)
    : _now = now ?? DateTime.now,
      _failuresKey = '${prefix}_failed_attempts',
      _lockedUntilKey = '${prefix}_locked_until_ms';

  final DateTime Function() _now;

  static const int freeAttempts = 5;
  static const Duration baseLockout = Duration(seconds: 30);
  static const Duration maxLockout = Duration(minutes: 30);

  final String _failuresKey;
  final String _lockedUntilKey;

  /// How long until the next attempt is allowed; null when it is allowed now.
  Future<Duration?> retryAfter() async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_lockedUntilKey);
    if (until == null) return null;
    final remaining = Duration(
      milliseconds: until - _now().millisecondsSinceEpoch,
    );
    if (remaining <= Duration.zero) return null;
    // A clock set backwards must not turn a 30-second lockout into a year.
    return remaining > maxLockout ? maxLockout : remaining;
  }

  /// Counts a wrong PIN; returns how many in a row now.
  Future<int> recordFailure() async {
    final prefs = await SharedPreferences.getInstance();
    final failures = (prefs.getInt(_failuresKey) ?? 0) + 1;
    await prefs.setInt(_failuresKey, failures);
    if (failures < freeAttempts) return failures;
    final lockout = lockoutAfter(failures);
    await prefs.setInt(
      _lockedUntilKey,
      _now().add(lockout).millisecondsSinceEpoch,
    );
    return failures;
  }

  Future<void> recordSuccess() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_failuresKey);
    await prefs.remove(_lockedUntilKey);
  }

  /// The lockout imposed after the [failures]-th consecutive failure.
  static Duration lockoutAfter(int failures) {
    if (failures < freeAttempts) return Duration.zero;
    final doublings = min(failures - freeAttempts, 16);
    final ms = baseLockout.inMilliseconds * (1 << doublings);
    return ms >= maxLockout.inMilliseconds
        ? maxLockout
        : Duration(milliseconds: ms);
  }

  /// «تلاش‌های ناموفق زیاد بود؛ …» — what every PIN screen says while locked.
  static String lockoutMessage(Duration wait) {
    final seconds = wait.inMilliseconds / 1000;
    final amount = seconds < 60
        ? '${PersianUtils.toPersianNumber(seconds.ceil().toString())} ثانیه'
        : '${PersianUtils.toPersianNumber((seconds / 60).ceil().toString())} دقیقه';
    return 'تلاش‌های ناموفق زیاد بود؛ $amount دیگر دوباره امتحان کنید';
  }
}
