import 'package:communication_super_app/core/utils/search_text.dart';

/// Finds the one-time code inside an SMS body, so the bubble can offer «کپی
/// ۱۲۳۴۵» instead of making the user select five digits out of a paragraph with
/// a text handle — the one affordance Google Messages puts on a plain SMS.
///
/// Two rules keep it from firing on every number in the inbox, and both are
/// load-bearing: the message has to *say* it is carrying a code (a bank's
/// «مبلغ ۱۵۰۰۰» is not one), and the digits have to stand alone (a date, a time,
/// an amount with separators and a phone number all look like a code otherwise).
class OneTimeCode {
  OneTimeCode._();

  /// Shortest and longest run of digits that can be a code. Four is the
  /// shortest anyone issues; past eight it is an account or a card number.
  static const int _minLength = 4;
  static const int _maxLength = 8;

  /// Words that make a number a *code*. Folded (see [SearchText.fold]), so
  /// «تأیید» and «تایید» are one entry and «ي»-spelled variants match too.
  ///
  /// Persian first — the app's mail is Persian — then the English words that
  /// turn up in international senders' messages.
  static final List<String> _keywords = [
    for (final w in const [
      'رمز',
      'رمز پویا',
      'کد',
      'کد تایید',
      'کد ورود',
      'کد فعالسازی',
      'کد یکبار مصرف',
      'پسورد',
      'گذرواژه',
      'احراز',
      'otp',
      'code',
      'pin',
      'password',
      'passcode',
      'verification',
      'verify',
      'auth',
    ])
      SearchText.fold(w),
  ];

  /// Characters that, sitting next to a run of digits, say it is part of a
  /// bigger number rather than a code of its own: an amount's separators, a
  /// date's slashes, a time's colon, a decimal point, a phone number's dashes.
  static const String _joiners = '/:.,-+٬،٫';

  /// Units that turn the run before them into a **price**, not a code.
  ///
  /// This is the false positive that matters here: «کد تخفیف ۳۰۰۰۰۰ تومانی»
  /// says «کد» and then quotes an amount, and offering to copy the amount is
  /// worse than offering nothing — it is the wrong number under the right
  /// label. Folded, so «تومان»/«تومانی» are both caught by prefix.
  static final List<String> _units = [
    for (final w in const [
      'تومان',
      'ريال',
      'ریال',
      'هزار',
      'میلیون',
      'میلیارد',
      'درصد',
      'روز',
      'ساعت',
      'دقیقه',
      '%',
    ])
      SearchText.fold(w),
  ];

  /// A code with this many trailing zeros is a round number, i.e. a sum of
  /// money or a quantity. Codes are issued from a random range and effectively
  /// never come out this round.
  static const int _maxTrailingZeros = 3;

  static final RegExp _digitRun = RegExp(r'\d+');

  /// The code in [body], as ASCII digits, or null when the message is not
  /// carrying one.
  ///
  /// The answer is ASCII whatever the message used: this string is pasted into
  /// another app's field, and Persian digits would be useless there.
  static String? find(String body) {
    if (body.isEmpty) return null;
    // One fold for the whole body: it maps ۱۲۳ → 123 as well as the letters, so
    // a code written in Persian digits is found and returned in the form the
    // user can actually paste. Folding also collapses the whitespace, which is
    // why the keyword search below can be a plain `contains`.
    final folded = SearchText.fold(body);
    if (folded.isEmpty) return null;

    final keywordAt = _firstKeyword(folded);
    if (keywordAt < 0) return null;

    String? best;
    var bestDistance = -1;
    for (final match in _digitRun.allMatches(folded)) {
      final digits = match.group(0)!;
      if (digits.length < _minLength || digits.length > _maxLength) continue;
      if (_joinedToMore(folded, match.start, match.end)) continue;
      if (_isAmount(folded, digits, match.end)) continue;
      // Nearest run to the word that announced the code — «رمز پویا: 84213 -
      // مبلغ 25000» must copy the password, not the amount.
      final distance = (match.start - keywordAt).abs();
      if (best == null || distance < bestDistance) {
        best = digits;
        bestDistance = distance;
      }
    }
    return best;
  }

  /// Index of the first code-announcing word in [folded], or -1.
  static int _firstKeyword(String folded) {
    var first = -1;
    for (final word in _keywords) {
      final at = folded.indexOf(word);
      if (at >= 0 && (first < 0 || at < first)) first = at;
    }
    return first;
  }

  /// Whether the run [start, end) is a slice of a longer number — the test that
  /// keeps «۱۴۰۵/۰۵/۲۰» and «۱,۵۰۰,۰۰۰» from being read as codes.
  ///
  /// The separator alone is not enough: a code ending a sentence («کد: ۱۲۳۴۵.»)
  /// carries a full stop too. It only joins when there are **digits on the far
  /// side of it**, which is what a date, a time and a thousands separator all
  /// have and a sentence does not.
  static bool _joinedToMore(String folded, int start, int end) {
    if (start >= 2 &&
        _joiners.contains(folded[start - 1]) &&
        _isDigit(folded[start - 2])) {
      return true;
    }
    if (end + 1 < folded.length &&
        _joiners.contains(folded[end]) &&
        _isDigit(folded[end + 1])) {
      return true;
    }
    return false;
  }

  /// Whether the run reads as a quantity rather than a code: a unit follows it,
  /// or it is too round to have been issued.
  static bool _isAmount(String folded, String digits, int end) {
    var zeros = 0;
    for (var i = digits.length - 1; i >= 0 && digits[i] == '0'; i--) {
      zeros++;
    }
    if (zeros >= _maxTrailingZeros) return true;
    // Only what immediately follows counts — one optional space, then the word.
    final tail = folded.substring(end, (end + 12).clamp(end, folded.length));
    final next = tail.startsWith(' ') ? tail.substring(1) : tail;
    return _units.any(next.startsWith);
  }

  static bool _isDigit(String c) {
    final code = c.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }
}
