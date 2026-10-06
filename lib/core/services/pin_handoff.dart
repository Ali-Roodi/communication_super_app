import 'package:flutter/foundation.dart';

/// The app PIN the user has just typed, handed to the one place that may
/// reuse it: opening the secure section from «پیام رمز جدید».
///
/// That notification used to ask for the same PIN twice — once by the app
/// lock, once by the secure section right behind it. The app lock now
/// [offer]s the PIN it accepted; the secure launch action [claim]s it (or
/// waits for it, when the notification arrived before the lock screen was
/// answered) and opens the section with it.
///
/// It lives in memory only, is good for [lifetime] at most, and is handed
/// out once: a launch that is not the secure notification never claims it.
/// Expiry is checked by time rather than a timer — a Dart string cannot be
/// scrubbed from memory anyway, and a timer would outlive every widget test
/// that types a PIN.
class PinHandoff {
  PinHandoff._();
  static final PinHandoff instance = PinHandoff._();

  static const lifetime = Duration(seconds: 15);

  /// The clock; tests move it.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  String? _pin;
  DateTime? _offeredAt;
  void Function(String pin)? _waiter;
  DateTime? _waitingSince;

  bool _fresh(DateTime? at) => at != null && now().difference(at) <= lifetime;

  /// The app lock accepted [pin].
  void offer(String pin) {
    final waiter = _waiter;
    final waiting = _fresh(_waitingSince);
    _waiter = null;
    _waitingSince = null;
    if (waiter != null && waiting) {
      _forget();
      waiter(pin);
      return;
    }
    _pin = pin;
    _offeredAt = now();
  }

  /// The secure notification's launch: [use] gets the PIN if the app lock
  /// took it a moment ago, or as soon as the app lock takes it within
  /// [lifetime]. Never called otherwise.
  void claim(void Function(String pin) use) {
    final pin = _pin;
    final fresh = _fresh(_offeredAt);
    _forget();
    if (pin != null && fresh) {
      _waiter = null;
      _waitingSince = null;
      use(pin);
      return;
    }
    _waiter = use;
    _waitingSince = now();
  }

  void _forget() {
    _pin = null;
    _offeredAt = null;
  }
}
