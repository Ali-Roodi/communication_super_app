import 'package:flutter/widgets.dart';

import 'persian_utils.dart';

/// «اندازه متن پیام» — how much bigger (or smaller) than normal the text in a
/// conversation is drawn.
///
/// A conversation is the one screen in this app that is nothing but text, read
/// by people of every eyesight, and the phone-wide font size is a poor answer:
/// turning it up to read an SMS turns the whole system up. Google Messages'
/// own answer is a pinch on the thread, and that is what this backs —
/// [ConversationScreen] scales its whole subtree, so bubbles, timestamps and
/// the composer all move together.
///
/// The value multiplies the platform's scaling rather than replacing it (see
/// [MessageTextScaler]): a user who has already turned Android's font size up
/// must not have it silently reset to 1.0 by opening a chat.
class MessageTextScale {
  MessageTextScale._();

  /// Normal size. Also what an install that never touched this has.
  static const double normal = 1.0;

  /// The range a pinch (and the settings row) may reach.
  ///
  /// Smaller than 0.8 stops being readable and larger than 2.0 fits about four
  /// words on a line, at which point a bubble is a column of one-word rows.
  static const double min = 0.8;
  static const double max = 2.0;

  /// The steps «اندازه متن پیام» offers, and what a pinch snaps to on release.
  static const List<double> steps = [0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0];

  static double clamp(double value) =>
      value.isNaN ? normal : value.clamp(min, max);

  /// The step nearest [value] — a pinch lands on an arbitrary factor and is
  /// settled onto one of the offered sizes so it matches what the settings row
  /// shows.
  static double snap(double value) {
    final v = clamp(value);
    var best = steps.first;
    for (final step in steps) {
      if ((step - v).abs() < (best - v).abs()) best = step;
    }
    return best;
  }

  /// «۱۳۰٪» — how a size is named in the UI.
  static String label(double value) =>
      '${PersianUtils.toPersianNumber('${(value * 100).round()}')}٪';
}

/// The platform's own text scaling, multiplied by the app's message scale.
///
/// Composed rather than replaced: `TextScaler.linear(ours)` would throw away
/// Android 14's non-linear scaling curve *and* whatever size the user set
/// system-wide, so a chat would render smaller than the rest of the phone for
/// anyone who had turned accessibility text up.
///
/// [==] and [hashCode] are implemented on purpose. `MediaQueryData` equality
/// includes the scaler, and a fresh unequal instance on every build would make
/// every text widget in the conversation rebuild once per frame.
@immutable
class MessageTextScaler extends TextScaler {
  final TextScaler base;
  final double factor;

  const MessageTextScaler({required this.base, required this.factor});

  @override
  double scale(double fontSize) => base.scale(fontSize * factor);

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  // `clamp` is deliberately NOT overridden: TextScaler's own implementation
  // wraps this scaler, which clamps the *composed* result. Clamping the base
  // instead would apply the caller's bounds to the platform factor and then
  // multiply past them.

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageTextScaler &&
          other.base == base &&
          other.factor == factor);

  @override
  int get hashCode => Object.hash(base, factor);
}
