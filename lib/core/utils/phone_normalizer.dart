/// Phone number normalization utilities for Iranian mobile numbers.
///
/// The canonical storage format (used as thread IDs) is pure digits with no
/// separators, e.g. `989190961805`.  The display format is the national
/// 11-digit form starting with `0`, e.g. `09190961805`.
///
/// Supported input variants:
///   - `+989190961805`  (E.164 international)
///   - `00989190961805` (international with 00 prefix)
///   - `989190961805`   (country code, no prefix)
///   - `09190961805`    (national, already correct)
///   - `9190961805`     (national, missing leading zero)
///   - Numbers with spaces, dashes, or parentheses are stripped first.
class PhoneNormalizer {
  PhoneNormalizer._();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns the number in national display format: `09xxxxxxxxx`.
  ///
  /// If the number cannot be recognized as an Iranian mobile / landline number
  /// the digits-only string is returned as a safe fallback.  Never throws.
  static String toNational(String phone) {
    final digits = _digitsOnly(phone);
    if (digits.isEmpty) return phone.trim();

    // 0098... → strip 0098 → 98... → apply country-code rule below
    final d = digits.startsWith('0098') ? digits.substring(2) : digits;

    if (d.length == 12 && d.startsWith('98')) {
      // E.g. 989190961805 → 09190961805
      return '0${d.substring(2)}';
    }
    if (d.length == 11 && d.startsWith('0')) {
      // Already national: 09190961805
      return d;
    }
    if (d.length == 10 && d.startsWith('9')) {
      // Missing leading zero: 9190961805 → 09190961805
      return '0$d';
    }

    // Unknown format – return digits only as a safe fallback
    return d.isNotEmpty ? d : phone.trim();
  }

  /// Returns the canonical thread-ID form: pure digits, no separators.
  ///
  /// This matches the format produced by `SmsService._normalizePhoneNumber`
  /// so that thread IDs are consistent across the receive and send pipelines.
  static String toThreadId(String phone) {
    final digits = _digitsOnly(phone);
    return digits.isNotEmpty ? digits : phone.trim();
  }

  /// Returns `true` if [a] and [b] refer to the same phone number regardless
  /// of formatting differences.
  static bool sameNumber(String a, String b) {
    if (a == b) return true;
    final da = _digitsOnly(a);
    final db = _digitsOnly(b);
    if (da.isEmpty || db.isEmpty) return false;
    // Compare canonical digits (strip leading country-code 0098 / 98 / 0)
    return _canonical(da) == _canonical(db);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static String _digitsOnly(String phone) =>
      phone.replaceAll(RegExp(r'[^\d]'), '');

  /// Strips the leading `98` (Iran country code) or leading `0` so that
  /// `989190961805`, `09190961805` and `9190961805` all compare equal.
  static String _canonical(String digits) {
    if (digits.startsWith('0098')) return digits.substring(4);
    if (digits.startsWith('98') && digits.length == 12) return digits.substring(2);
    if (digits.startsWith('0') && digits.length == 11) return digits.substring(1);
    return digits;
  }
}
