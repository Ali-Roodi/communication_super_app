import 'persian_utils.dart';

/// USSD / MMI codes found inside a message body.
///
/// Iranian carriers send them constantly («برای شارژ *140*11# را شماره‌گیری
/// کنید») and in a Persian message they were unusable for two independent
/// reasons, both fixed here:
///
/// 1. **They rendered backwards.** `*` and `#` are bidi-neutral and the digit
///    runs are European Numbers, so inside an RTL paragraph the Unicode bidi
///    algorithm resolves the separators to the paragraph's own direction and
///    reorders the pieces: `*140*11#` came out as `#11*140*`. Copying that by
///    hand dials the wrong code — or nothing. [isolate] wraps the run in an
///    LTR isolate, which is the only thing that fixes it inside one paragraph.
/// 2. **They were not tappable.** The one thing anyone does with a code in a
///    message is dial it, and the alternative was a long-press, a word
///    selection, a copy, and a paste into the keypad.
///
/// The shape rule is AOSP's own ([`TelephonyConnectionService`], mirrored in
/// `CallInCallService.isMmiCode`): starts with `*` or `#`, ends with `#`. That
/// trailing `#` is load-bearing — «#31#0912…» is an MMI *prefix* on a real call
/// and is deliberately not one of these.
class UssdCode {
  UssdCode._();

  /// Bidi isolate the display text is wrapped in. LRI … PDI (U+2066/U+2069):
  /// isolates rather than embeddings, so the code cannot influence the
  /// direction resolution of the Persian words around it.
  static const String isolateStart = '\u2066';
  static const String isolatePop = '\u2069';

  /// Persian (۰-۹) and Arabic-Indic (٠-٩) digits are dialable too — a carrier
  /// that writes «*۷۸۰*۰#» means the same code.
  static const String _digits = r'0-9۰-۹٠-٩';

  /// A USSD/MMI code as written in a message.
  ///
  /// * opens with `*` or `#` (or `**` / `##`, which register/erase a service),
  /// * carries at least one digit,
  /// * closes with `#`.
  ///
  /// The leading `(?<![...])` keeps it from firing on the tail of a longer
  /// token, and the length cap keeps a line of stars and hashes from being read
  /// as one enormous code (real MMI strings are far under 40 characters).
  ///
  /// The trailing `(?![digits])` is what tells «#31#09121234567» — an MMI
  /// *prefix* on a real call, caller-ID suppression — apart from a standalone
  /// code. Without it the leading «#31#» matched on its own, and tapping it
  /// would have asked the network to suppress caller ID and nothing else.
  static final RegExp pattern = RegExp(
    '(?<![$_digits*#])'
    '[*#]{1,2}'
    '[$_digits*#]{0,38}'
    '[$_digits]'
    '[$_digits*#]{0,38}'
    '#'
    '(?![$_digits])',
  );

  /// The **mirror image** of a code: `#` … `*`, e.g. «#5*555*».
  ///
  /// Iranian carriers really do send them that way. Verified on a live Irancell
  /// SMS: the Persian half stores «خرید بسته اینترنت: #5*555*» — the sender
  /// typed the code in *visual* order so that an RTL renderer, which pushes the
  /// bidi-neutral `*` and `#` to the outside, would show «*555*5#». It reads
  /// correctly and is completely undialable: copying it hands the keypad a
  /// string that is backwards.
  ///
  /// This is the «اصلاح خودکار» half of the feature. The run is put back into
  /// dialling order for both the tap and the text that is drawn.
  ///
  /// It must end in `*`, never `#`. A run that ends in `#` is a well-formed
  /// code *as written* («#100#»), and the forward reading always wins — the
  /// mirror rule only ever rescues a run that cannot be read forwards at all.
  static final RegExp mirroredPattern = RegExp(
    '(?<![$_digits*#])'
    '#'
    '[$_digits*#]{0,38}'
    '[$_digits]'
    '[$_digits*#]{0,38}'
    r'\*'
    '(?![$_digits*#])',
  );

  /// True when [text] is *entirely* one USSD code — used to tell a matched
  /// link apart from a phone number without re-running the scan.
  static bool isCode(String text) {
    final m = pattern.firstMatch(text);
    return m != null && m.start == 0 && m.end == text.length;
  }

  /// [text] in dialling order, or null when it is not a code at all.
  ///
  /// Forward first, always: a run that reads as a code as written is that code,
  /// even though many of them («#100#») reverse into something equally
  /// well-formed. Only a run that is *not* a code forwards is re-read backwards.
  static String? correctedOf(String text) {
    if (isCode(text)) return text;
    final reversed = String.fromCharCodes(text.runes.toList().reversed);
    return isCode(reversed) ? reversed : null;
  }

  /// [text] as the string to hand telephony, or null when it is not a code.
  static String? dialableOf(String text) {
    final corrected = correctedOf(text);
    return corrected == null ? null : toDialable(corrected);
  }

  /// The code as it must reach telephony: ASCII digits, nothing else stripped.
  ///
  /// `*` `#` `,` `;` all survive on purpose — they are dialable characters, and
  /// stripping them is exactly the bug that made «*100#» arrive as «100».
  ///
  /// Arabic-Indic digits are folded here rather than through
  /// [PersianUtils.toEnglishNumber], which only knows the Persian set: a code
  /// written «*٧٨٠*٠#» has to dial too.
  static String toDialable(String code) {
    final buffer = StringBuffer();
    for (final rune in PersianUtils.toEnglishNumber(code).runes) {
      // ٠ (U+0660) … ٩ (U+0669)
      if (rune >= 0x0660 && rune <= 0x0669) {
        buffer.writeCharCode(0x30 + (rune - 0x0660));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString().replaceAll(RegExp(r'[^0-9*#+,;]'), '');
  }

  /// [text] wrapped so it lays out left-to-right inside an RTL paragraph.
  ///
  /// Applied at render time only. Nothing stored ever carries these characters:
  /// the DB row must stay byte-identical to what the SMS provider holds.
  static String isolate(String text) => '$isolateStart$text$isolatePop';
}
