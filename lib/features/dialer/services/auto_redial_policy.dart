/// «تماس مجدد خودکار» — the settings that decide it, readable from anywhere.
///
/// The decision is made in `DialerBloc` on a DISCONNECTED event, and a bloc
/// cannot read another bloc's state; the same mirror pattern as
/// `SmsService.deliveryReports` and `DateFormatter.calendar`: `SettingsBloc`
/// writes these on load and on every change, and nothing else does.
///
/// Off by default, like Samsung's own «Auto redial»: a phone that starts
/// dialling by itself has to be something the user asked for.
class AutoRedialPolicy {
  AutoRedialPolicy._();

  /// Whether a failed outgoing call is dialled again at all.
  static bool enabled = false;

  /// How many times, after the call the user placed. «تعداد تلاش‌ها».
  static int maxAttempts = defaultAttempts;

  static const int defaultAttempts = 3;

  /// The choices the settings page offers.
  static const List<int> attemptChoices = [1, 2, 3, 5, 10];

  /// How long the ended-call screen counts down before the next attempt.
  /// Long enough to read «تلاش ۱ از ۳» and press «لغو», short enough that a
  /// busy line is tried again while it is still worth trying. Not a setting;
  /// mutable only so the bloc tests do not have to wait five real seconds.
  static Duration delay = defaultDelay;

  static const Duration defaultDelay = Duration(seconds: 5);

  /// [value] as the settings page would store it: one of [attemptChoices],
  /// else the default — a preference written by another build must not make
  /// the phone dial ten thousand times.
  static int clampAttempts(int? value) =>
      value != null && attemptChoices.contains(value) ? value : defaultAttempts;
}
