import 'package:flutter/material.dart';
import '../utils/persian_utils.dart';

/// Circular contact avatar with the contact's initial.
///
/// The colour is picked deterministically from the name and then *toned for
/// the current brightness*, the way Google Phone / Contacts do it: a light,
/// desaturated fill with dark text on a light theme, a deeper fill with light
/// text on a dark theme. A single saturated swatch would glare on the light
/// page and wash out on the dark one.
class AvatarWidget extends StatelessWidget {
  final String name;
  final double size;
  final Color? backgroundColor;

  const AvatarWidget({
    super.key,
    required this.name,
    this.size = 48,
    this.backgroundColor,
  });

  /// Base hues of the palette (degrees). Chosen to stay distinguishable at the
  /// small sizes a list uses.
  static const List<double> _hues = [4, 25, 45, 90, 145, 185, 215, 265, 315];

  /// Deterministic hue for [name]. Hashes the whole name, not just its
  /// initial: otherwise every contact in the «A» section would share a swatch.
  static double _hueFor(String name) {
    var hash = 0;
    for (final unit in name.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _hues[hash % _hues.length];
  }

  /// Deterministic fill for [name] under [brightness].
  static Color fillFor(String name, Brightness brightness) {
    if (name.isEmpty) {
      return brightness == Brightness.light
          ? const Color(0xFFDADCE0)
          : const Color(0xFF3C4043);
    }
    return brightness == Brightness.light
        ? HSLColor.fromAHSL(1, _hueFor(name), 0.78, 0.76).toColor()
        : HSLColor.fromAHSL(1, _hueFor(name), 0.40, 0.40).toColor();
  }

  /// Initial colour that pairs with [fillFor].
  ///
  /// Google Contacts writes the initial in a *deep tint of the swatch's own
  /// hue* — a purple «A» on lilac, a brown «A» on amber — not in neutral black,
  /// which is what makes the avatars read as one family instead of stickers.
  static Color onFillFor(String name, Brightness brightness) {
    if (name.isEmpty) {
      return brightness == Brightness.light ? const Color(0xFF444746) : Colors.white;
    }
    return brightness == Brightness.light
        ? HSLColor.fromAHSL(1, _hueFor(name), 0.80, 0.24).toColor()
        : HSLColor.fromAHSL(1, _hueFor(name), 0.55, 0.92).toColor();
  }

  /// The glyph to draw, or empty when the avatar should fall back to the person
  /// icon.
  ///
  /// Phone numbers reach this widget already wrapped in bidi controls and
  /// converted to Persian digits, so a naive "first character" would render an
  /// invisible mark. Strip the controls and only accept a *letter* — an unsaved
  /// number gets the person glyph, like Google Messages shows for one.
  static final RegExp _bidiControls = RegExp(
    '[\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  /// Compiled once, like [_bidiControls] above it: this runs from `build` for
  /// every avatar in every list, and `\p{L}` is the expensive kind to compile.
  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);

  static String initialFor(String name) {
    final cleaned = name.replaceAll(_bidiControls, '').trimLeft();
    if (cleaned.isEmpty) return '';
    final first = cleaned[0];
    return _letter.hasMatch(first)
        ? PersianUtils.getInitials(cleaned)
        : '';
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final color = backgroundColor ?? fillFor(name, brightness);
    final initial = initialFor(name);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: initial.isEmpty
          ? Icon(
              Icons.person,
              size: size * 0.55,
              color: onFillFor(name, brightness).withValues(alpha: 0.75),
            )
          : Text(
              initial,
              style: TextStyle(
                color: onFillFor(name, brightness),
                fontSize: size * 0.44,
                fontWeight: FontWeight.w400,
                height: 1,
              ),
            ),
    );
  }
}
