/// Whether an SMS conversation can be answered at all.
///
/// A phone's inbox is full of senders that are not phone numbers: «Snapp»,
/// «DIGIPAY», «MissedCalls», «BaIrancell», every bank's alphanumeric sender ID.
/// GSM calls these *alphanumeric originating addresses* — they exist so a
/// message can be signed with a name, and they carry no route back. Offering a
/// composer under one is offering a send that the radio refuses (or, worse,
/// silently swallows) every single time.
///
/// The rule is the platform's own (`PhoneNumberUtils.isWellFormedSmsAddress`,
/// which is also what Google Messages disables its composer on): an address is
/// a possible destination when it is made of dialable characters. Numeric
/// service numbers (`5000301630`, `+9890009659`) are deliberately **left
/// replyable** — Iranian carriers and services ask for replies to them
/// constantly («برای لغو عدد ۱۱ را به همین شماره ارسال کنید»), so treating a
/// short code as unreachable would break a common, working case.
class SmsAddress {
  SmsAddress._();

  /// Everything a dialable address may be made of, after Persian and
  /// Arabic-Indic digits have been folded to ASCII: digits, the international
  /// `+`, the separators a carrier or a contact record may include, and the
  /// two MMI characters.
  static final RegExp _dialable = RegExp(r'^[0-9+\-()\s.*#]+$');

  static final RegExp _persoArabicDigits = RegExp(r'[۰-۹٠-٩]');
  static final RegExp _nonDigits = RegExp(r'[^0-9]');

  /// Whether an SMS may be sent **to** [address].
  ///
  /// False for an alphanumeric sender ID and for anything with too few digits
  /// to be a destination at all. Never throws.
  static bool canReceive(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return false;
    final folded = _foldDigits(trimmed);
    if (!_dialable.hasMatch(folded)) return false;
    // Three digits is the floor: the shortest thing anyone can send to. Below
    // it the address is punctuation, not a number.
    return folded.replaceAll(_nonDigits, '').length >= 3;
  }

  /// Converts Persian (۰–۹) and Arabic-Indic (٠–٩) digits to ASCII, leaving
  /// everything else alone. Same table as `PhoneNormalizer`.
  static String _foldDigits(String s) {
    if (!s.contains(_persoArabicDigits)) return s;
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    final buffer = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      final pi = persian.indexOf(ch);
      if (pi >= 0) {
        buffer.write(pi);
        continue;
      }
      final ai = arabic.indexOf(ch);
      if (ai >= 0) {
        buffer.write(ai);
        continue;
      }
      buffer.write(ch);
    }
    return buffer.toString();
  }
}
