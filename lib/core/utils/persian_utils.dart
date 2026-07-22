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
  static String displayPhone(String raw) => toPersianNumber(formatPhone(raw));

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
