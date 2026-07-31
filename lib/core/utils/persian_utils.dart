import 'package:flutter/material.dart';
import '../constants/app_constants.dart';

class PersianUtils {
  static String toPersianNumber(String number) {
    String result = number;
    AppConstants.persianNumbers.forEach((english, persian) {
      result = result.replaceAll(english, persian);
    });
    return result;
  }

  static String toEnglishNumber(String number) {
    String result = number;
    AppConstants.persianNumbers.forEach((english, persian) {
      result = result.replaceAll(persian, english);
    });
    return result;
  }

  /// Display-only phone formatting: strips stored separators (e.g. dashes
  /// saved in the contact) and regroups Iranian numbers with spaces —
  /// `0935 645 5230` for mobiles, `021 1234 5678` for landlines. Purely
  /// cosmetic: search/matching keep working on the raw digits.
  static String formatPhone(String raw) {
    var d = toEnglishNumber(raw).replaceAll(RegExp(r'[^\d+]'), '');
    if (d.startsWith('+98')) {
      d = '0${d.substring(3)}';
    } else if (d.startsWith('0098')) {
      d = '0${d.substring(4)}';
    }
    if (d.length == 11 && d.startsWith('09')) {
      return '${d.substring(0, 4)} ${d.substring(4, 7)} ${d.substring(7)}';
    }
    if (d.length == 11 && d.startsWith('0')) {
      return '${d.substring(0, 3)} ${d.substring(3, 7)} ${d.substring(7)}';
    }
    return raw;
  }

  /// [formatPhone] + Persian digits — the standard way to render a phone
  /// number anywhere in the UI.
  ///
  /// The result is wrapped in an LTR embedding (U+202A … U+202C) so the number
  /// always reads left-to-right — with its space-separated groups in the right
  /// order — even inside an RTL paragraph. Without it, an RTL layout reorders
  /// the groups (e.g. «0919 096 1805» renders as «1805 096 0919»). Purely a
  /// display concern: matching/search still use the raw digits.
  /// Memoized: this is called from row builds \u2014 every contact row, call-log
  /// tile and thread header \u2014 and `formatPhone` + `toPersianNumber` walk the
  /// string ~20 times each (ten `replaceAll` passes per digit map, twice, plus
  /// a RegExp). Doing that per number per frame while a list is flung is pure
  /// waste; the keys converge on the numbers stored on the device.
  static final Map<String, String> _displayCache = {};
  static const int _maxDisplayCache = 4096;

  static String displayPhone(String raw) {
    final cached = _displayCache[raw];
    if (cached != null) return cached;

    final formatted = toPersianNumber(formatPhone(raw));
    if (formatted.isEmpty) return formatted;
    final display = '\u202A$formatted\u202C';
    // A plain cap rather than an LRU: the key space is the phone numbers on
    // the device, so the map converges and stops growing.
    if (_displayCache.length >= _maxDisplayCache) _displayCache.clear();
    _displayCache[raw] = display;
    return display;
  }

  static String getInitials(String name) {
    if (name.isEmpty) return '';
    return name[0].toUpperCase();
  }

  static int getAvatarColorIndex(String name) {
    if (name.isEmpty) return 0;
    return name.codeUnitAt(0) % AppConstants.avatarColors.length;
  }

  static Color getAvatarColor(String name) {
    final index = getAvatarColorIndex(name);
    return Color(AppConstants.avatarColors[index]);
  }
}
