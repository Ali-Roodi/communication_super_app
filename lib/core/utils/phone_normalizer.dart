/// Phone number normalization utilities for Iranian mobile/landline numbers.
///
/// ## Canonical format
/// The canonical storage format used as `thread_id` in the messages table is
/// the **national 11-digit form**: `09xxxxxxxxx`.  All variants of the same
/// number map to the same string, which prevents duplicate threads when a
/// sender uses E.164 (`+989...`) and the app uses the local format (`09...`).
///
/// ## Supported input variants
///   - `+989190961805`   (E.164 international)
///   - `00989190961805`  (international with 00 prefix)
///   - `989190961805`    (country code, no prefix)
///   - `09190961805`     (national, already correct)
///   - `9190961805`      (national, missing leading zero)
///   - Numbers with spaces, dashes, dots, or parentheses (stripped)
///   - Persian digits (۰–۹) and Arabic-Indic digits (٠–٩) are converted first
class PhoneNormalizer {
  PhoneNormalizer._();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns the number in national display format: `09xxxxxxxxx`.
  ///
  /// For non-Iranian numbers (landlines, short codes, etc.) the cleaned
  /// digit-only string is returned as a safe fallback.  Never throws.
  static String toNational(String phone) {
    final digits = _digitsOnly(phone);
    if (digits.isEmpty) return phone.trim();

    // 0098… → treat as 98… (strip the extra leading 00)
    final d = digits.startsWith('0098') ? digits.substring(2) : digits;

    // 989xxxxxxxx (12 digits, country code) → 09xxxxxxxx
    if (d.length == 12 && d.startsWith('98')) {
      return '0${d.substring(2)}';
    }
    // 09xxxxxxxx (11 digits, national form) → already correct
    if (d.length == 11 && d.startsWith('0')) {
      return d;
    }
    // 9xxxxxxxxx (10 digits, missing leading zero) → 09xxxxxxxxx
    if (d.length == 10 && d.startsWith('9')) {
      return '0$d';
    }

    // Unknown format — return the cleaned digit string as a safe fallback
    return d.isNotEmpty ? d : phone.trim();
  }

  /// Returns the canonical **thread-ID** string for [phone].
  ///
  /// This is `toNational()` — always the national `09xxxxxxxxx` form — so
  /// that thread IDs are consistent regardless of how the sender/carrier
  /// formats the number.
  static String toThreadId(String phone) => toNational(phone);

  /// Alias matching the `PhoneNumberUtils.normalize()` name used in the plan.
  static String normalize(String phone) => toNational(phone);

  /// Returns `true` if [a] and [b] refer to the same phone number regardless
  /// of formatting differences (including E.164 vs. national format).
  static bool sameNumber(String a, String b) {
    if (a == b) return true;
    return toNational(a) == toNational(b);
  }

  /// How many trailing digits a **loose** match compares. Android's own value
  /// (`ContactsContract`'s `min_match`, 7 by default) — this is the rule
  /// `PhoneLookup` matches by, and matching it is the whole point.
  static const int tailMatchLength = 7;

  /// The loose lookup key for [phone]: its last [tailMatchLength] digits, or
  /// empty when it has fewer than that (a short code, a service address).
  ///
  /// This exists because [toThreadId] and `PhoneLookup` **do not agree**, and
  /// the disagreement was visible: the incoming-call screen resolves a caller
  /// natively through `ContactsContract.PhoneLookup`, which compares only the
  /// trailing digits, while «اخیر» and the inbox resolve the same caller in Dart
  /// through an exact-equality index on [toThreadId]. So a contact saved without
  /// its area code (`۱۲۳۴۵۶۷۸` for a number that arrives as `۰۲۱۱۲۳۴۵۶۷۸`), or
  /// with a foreign trunk prefix this normalizer has no rule for, showed its
  /// **name** while the phone was ringing and its bare **number** in the call
  /// list a second later — «انگار که چنین مخاطبی ذخیره نشده».
  ///
  /// It is only ever a *fallback*, tried after the exact key misses, and only
  /// when the tail is unambiguous in the address book — which makes it strictly
  /// more conservative than the platform lookup it is catching up with.
  static String toTailKey(String phone) {
    final digits = _digitsOnly(phone);
    if (digits.length < tailMatchLength) return '';
    return digits.substring(digits.length - tailMatchLength);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Compiled once. `toNational` runs from inside `build` (a thread row prints
  /// its number) and once per contact per keystroke in the search, so building
  /// these per call meant compiling two regexes per visible row per frame.
  static final RegExp _nonDigits = RegExp(r'[^\d]');
  static final RegExp _persoArabicDigits = RegExp(r'[۰-۹٠-٩]');

  /// Strips all non-digit characters after converting Persian/Arabic digits.
  static String _digitsOnly(String phone) =>
      _toEnglishDigits(phone).replaceAll(_nonDigits, '');

  /// Converts Persian (۰–۹) and Arabic-Indic (٠–٩) digits to ASCII (0–9).
  /// All other characters are passed through unchanged.
  static String _toEnglishDigits(String s) {
    // Fast path — no conversion needed for pure ASCII
    if (!s.contains(_persoArabicDigits)) return s;

    const persian = '۰۱۲۳۴۵۶۷۸۹';
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    final buf = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      final pi = persian.indexOf(ch);
      if (pi >= 0) {
        buf.write(pi.toString());
        continue;
      }
      final ai = arabic.indexOf(ch);
      if (ai >= 0) {
        buf.write(ai.toString());
        continue;
      }
      buf.write(ch);
    }
    return buf.toString();
  }
}
