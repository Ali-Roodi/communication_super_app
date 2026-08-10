/// The alphabet the contacts list is bucketed and ordered by.
///
/// This used to live inside `ContactsListScreen` as private constants, which
/// was fine while the *provider* decided the order of the rows. It no longer
/// does: the address book is sorted in `ContactRepository` (so the SIM cards'
/// contacts interleave with the phone's instead of being appended at the end,
/// and so «نام خانوادگی» ordering is possible at all), and a list ordered by
/// one rule under an index bar ranked by another is a fast-scroll that lands
/// in the wrong place. One table, both callers.
library;

import 'package:flutter/widgets.dart';
import 'package:communication_super_app/core/utils/search_text.dart';

// Stock-phone style fast-scroll index. Which alphabet is shown follows the
// device language: Persian phone → Persian letters + '#', otherwise A–Z + '#'.
// '#' is always last and collects every initial outside the active alphabet.
const List<String> kLatinIndexLetters = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', //
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '#',
];

const List<String> kPersianIndexLetters = [
  'ا', 'ب', 'پ', 'ت', 'ث', 'ج', 'چ', 'ح', 'خ', 'د', 'ذ', 'ر', 'ز', 'ژ', //
  'س', 'ش', 'ص', 'ض', 'ط', 'ظ', 'ع', 'غ', 'ف', 'ق', 'ک', 'گ', 'ل', 'م', //
  'ن', 'و', 'ه', 'ی', '#',
];

/// Maps the Arabic-script variants a name can start with onto the canonical
/// Persian letter used for its section (e.g. «آرش» and «احمد» both → «ا»).
const Map<String, String> kPersianLetterAliases = {
  'آ': 'ا', 'أ': 'ا', 'إ': 'ا', 'ٱ': 'ا', 'ء': 'ا', //
  'ك': 'ک',
  'ي': 'ی', 'ى': 'ی', 'ئ': 'ی',
  'ة': 'ه', 'ۀ': 'ه',
  'ؤ': 'و',
};

/// `true` when the device language is Persian, so the contacts index should use
/// the Persian alphabet.
bool isPersianDeviceLocale() =>
    WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'fa';

/// The index alphabet for the current device language.
List<String> activeIndexLetters() =>
    isPersianDeviceLocale() ? kPersianIndexLetters : kLatinIndexLetters;

/// Section letter for [name] within the alphabet [letters]. Latin initials are
/// uppercased; Persian initials are folded onto their canonical letter
/// (آ → ا, ك → ک, …). Anything the active alphabet doesn't contain (digits,
/// symbols, or the *other* script) falls under '#'.
String sectionLetterFor(String name, List<String> letters) {
  final trimmed = name.trimLeft();
  if (trimmed.isEmpty) return '#';
  final first = trimmed[0];
  final folded = kPersianLetterAliases[first] ?? first.toUpperCase();
  return letters.contains(folded) && folded != '#' ? folded : '#';
}

/// Ordering rank of [letter] within [letters] ('#' and anything unknown last).
int letterRank(String letter, List<String> letters) {
  final i = letters.indexOf(letter);
  return i < 0 ? letters.length : i;
}

/// Collation for Persian names.
///
/// `String.compareTo` orders by UTF-16 code unit, and the Persian alphabet is
/// **not** in code-unit order — پ (0x067E), چ (0x0686), ژ (0x0698), گ (0x06AF)
/// and ک (0x06A9) all sit far outside the ب…ی run, so a naive sort scatters
/// them. This maps every folded character onto its rank in the alphabet and
/// compares the mapped strings instead.
///
/// The key is built **once per contact** and sorted with a plain `compareTo`:
/// building it inside the comparator would fold every name O(log n) times over
/// a whole address book.
class PersianCollator {
  PersianCollator._();

  /// Known letters occupy [_kBase] … [_kBase]+n; anything else is emitted
  /// behind [_kUnknown], so unknown scripts and symbols always sort last while
  /// still ordering deterministically among themselves.
  static const int _kBase = 0x100;
  static const int _kUnknown = 0xE000;

  static final Map<int, int> _rank = _buildRanks();

  static Map<int, int> _buildRanks() {
    final map = <int, int>{};
    var rank = 0;
    // Persian first, then Latin: on a Persian phone the Latin names live in
    // the '#' bucket anyway, and the section rank (below) dominates the key.
    for (final letter in kPersianIndexLetters) {
      if (letter == '#') continue;
      map[letter.codeUnitAt(0)] = rank++;
    }
    for (var c = 'a'.codeUnitAt(0); c <= 'z'.codeUnitAt(0); c++) {
      map[c] = rank++;
    }
    for (var c = '0'.codeUnitAt(0); c <= '9'.codeUnitAt(0); c++) {
      map[c] = rank++;
    }
    return map;
  }

  /// A key that sorts [name] the way the index bar is ranked: by section first
  /// (so the list order and the fast-scroll offsets can never disagree), then
  /// alphabetically inside the section.
  static String sortKey(String name, List<String> letters) {
    final section = letterRank(sectionLetterFor(name, letters), letters);
    final buffer = StringBuffer()..writeCharCode(_kBase + section);
    // `fold` normalises the Arabic/Persian letter variants, drops the harakat
    // and the ZWNJ, lowercases and collapses whitespace — exactly the
    // differences that must not change where a name sorts.
    for (final c in SearchText.fold(name).runes) {
      final r = _rank[c];
      if (r != null) {
        buffer.writeCharCode(_kBase + r);
      } else if (c == 0x20) {
        buffer.writeCharCode(0x20); // spaces sort before every letter
      } else {
        buffer
          ..writeCharCode(_kUnknown)
          ..writeCharCode(c);
      }
    }
    return buffer.toString();
  }
}
