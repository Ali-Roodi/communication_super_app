/// The number prefixes «مسدود کردن تماس‌های تبلیغاتی» refuses.
///
/// There is no official marker for an advertising call in Iran — no reserved
/// range, no caller-id flag — so this is a list the user owns. It starts with
/// `0942`, which the press reported in آذر ۱۴۰۴ as the prefix the recorded
/// advertising calls come from (عصر ایران). A saved contact is never refused
/// for its prefix (`CallRules`).
///
/// [normalize] mirrors `CallRules.normalizePrefix` in Kotlin, which re-checks
/// every prefix it is handed — change the two together.
abstract final class CallBlockPrefixes {
  static const List<String> defaults = ['0942'];

  /// A typed prefix (`0942`, `+98942`, `98942`, `942`, `۰۹۴۲`) in the national
  /// form numbers are compared in (`0942`); null when it is not usable — fewer
  /// than four digits matches half the country, and a foreign prefix is the
  /// international rule's business.
  static String? normalize(String input) {
    final digits = StringBuffer();
    for (final rune in input.runes) {
      final d = _digitValue(rune);
      if (d != null) digits.write(d);
    }
    final s = digits.toString();
    final String national;
    if (s.startsWith('0098')) {
      national = '0${s.substring(4)}';
    } else if (s.startsWith('98')) {
      national = '0${s.substring(2)}';
    } else if (s.startsWith('9')) {
      national = '0$s';
    } else {
      national = s;
    }
    return national.length >= 4 && national.startsWith('0') ? national : null;
  }

  /// [list] with [prefix] added, normalised, without duplicates; null when
  /// [prefix] is not usable.
  static List<String>? add(List<String> list, String prefix) {
    final normalized = normalize(prefix);
    if (normalized == null) return null;
    if (list.contains(normalized)) return list;
    return [...list, normalized];
  }

  /// ASCII, Persian (۰–۹) and Arabic-Indic (٠–٩) digits.
  static int? _digitValue(int rune) {
    if (rune >= 0x30 && rune <= 0x39) return rune - 0x30;
    if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0;
    if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660;
    return null;
  }
}
