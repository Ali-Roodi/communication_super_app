import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';

/// A phone number rendered the usual way ([PersianUtils.displayPhone]) with the
/// typed digits emphasised, the way Google Phone marks the part of a suggestion
/// the user has already dialled.
///
/// The highlight is recomputed against the *formatted* number rather than
/// carried over from the match: formatting normalises `+98…` to `0…`, so an
/// index taken on the raw number would land on the wrong digit.
class HighlightedPhone extends StatelessWidget {
  /// Compiled once — this widget is a list row, so it builds per contact.
  static final RegExp _nonDigits = RegExp(r'[^\d]');

  final String number;

  /// Digits the user typed. Empty (or not present in the number) renders the
  /// number unstyled.
  final String query;

  final TextStyle? style;

  const HighlightedPhone({
    super.key,
    required this.number,
    required this.query,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final display = PersianUtils.displayPhone(number);
    final digitsOnly = query.replaceAll(_nonDigits, '');
    if (digitsOnly.isEmpty) return Text(display, style: style);

    // Positions of the digit characters inside the formatted string, plus the
    // same digits in ASCII so the query can be searched for.
    final positions = <int>[];
    final buffer = StringBuffer();
    for (var i = 0; i < display.length; i++) {
      final ascii = PersianUtils.toEnglishNumber(display[i]);
      final code = ascii.length == 1 ? ascii.codeUnitAt(0) : -1;
      if (code >= 0x30 && code <= 0x39) {
        positions.add(i);
        buffer.write(ascii);
      }
    }

    final at = buffer.toString().indexOf(digitsOnly);
    if (at < 0 || at + digitsOnly.length > positions.length) {
      return Text(display, style: style);
    }

    final start = positions[at];
    final end = positions[at + digitsOnly.length - 1] + 1;
    final bold = (style ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w700,
      color: Theme.of(context).colorScheme.onSurface,
    );

    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (start > 0) TextSpan(text: display.substring(0, start)),
          TextSpan(text: display.substring(start, end), style: bold),
          if (end < display.length) TextSpan(text: display.substring(end)),
        ],
      ),
    );
  }
}
