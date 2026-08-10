import 'package:communication_super_app/core/utils/phone_normalizer.dart';

/// A hit from [PhoneQuery.match]: which digit form of the number matched, and
/// the range inside it — enough to highlight the digits the user typed.
class PhoneHit {
  const PhoneHit(this.digits, this.start, this.length);

  /// The digit form of the stored number the query was found in.
  final String digits;
  final int start;
  final int length;
}

/// A number search compiled once and run against many contacts.
///
/// Building the query's equivalent forms per *contact* (which is what a bare
/// `phoneContains(number, query)` loop does) repeats the same normalization
/// thousands of times per keystroke on a real address book. Every caller that
/// filters a list builds one of these and reuses it.
class PhoneQuery {
  PhoneQuery(String query) : needles = SearchText.queryForms(query);

  /// Equivalent digit forms of the typed query. `needles.first` is the digits
  /// exactly as typed; the rest are prefix-convention rewrites.
  final List<String> needles;

  bool get isEmpty => needles.isEmpty;

  /// Where this query matches [number], or null.
  ///
  /// The digits **as typed** match anywhere in the number (dialing the middle
  /// of a number is a normal way to find it), but a form derived by stripping a
  /// trunk `0` or a `98` country code only matches at the **start**: those
  /// digits are a prefix convention, not content. Without that asymmetry,
  /// searching `021…` for a landline also returned every mobile that happens to
  /// contain `21`.
  PhoneHit? match(String number) {
    if (needles.isEmpty) return null;
    final haystacks = SearchText.phoneForms(number);
    if (haystacks.isEmpty) return null;
    for (var n = 0; n < needles.length; n++) {
      final needle = needles[n];
      for (final haystack in haystacks) {
        final at = n == 0
            ? haystack.indexOf(needle)
            : (haystack.startsWith(needle) ? 0 : -1);
        if (at >= 0) return PhoneHit(haystack, at, needle.length);
      }
    }
    return null;
  }

  bool contains(String number) => match(number) != null;
}

/// A name compiled into the digits that would type it on a phone keypad, plus
/// the bookkeeping needed to report a hit back in the *original* string.
///
/// Built once per name and memoized ([SearchText.t9Of]): T9 runs over the whole
/// address book on every keypress, and rebuilding this per contact per digit is
/// the same mistake [PhoneQuery] exists to avoid.
class T9Name {
  const T9Name(this.digits, this.positions, this.wordStarts);

  /// One digit per letter of the folded name, spaces removed.
  final String digits;

  /// `positions[i]` is where `digits[i]`'s letter sits in the original name —
  /// folding drops characters (ZWNJ, harakat), so an index into [digits] would
  /// highlight the wrong letter.
  final List<int> positions;

  /// Indices into [digits] at which a word begins. A T9 query matches from a
  /// word start only: matching anywhere inside would answer «۴» with every
  /// contact whose name contains a «ر».
  final List<int> wordStarts;

  bool get isEmpty => digits.isEmpty;
}

/// Text folding for every place the app searches contacts by name or number.
///
/// A raw `String.contains` is not a search on a Persian address book: the same
/// name is stored with Arabic letters on one phone and Persian ones on another
/// («علي» vs «علی», «كامران» vs «کامران»), with or without a ZWNJ («محمد‌رضا»),
/// with or without diacritics, and a number the user types as `0912…` is stored
/// as `+98912…`. Matching those literally is what made the search miss contacts
/// that are plainly there.
class SearchText {
  SearchText._();

  /// Arabic-script letters folded onto the canonical Persian one, so a name
  /// typed with either keyboard matches a name stored with either keyboard.
  static const Map<int, int> _letterFolds = {
    0x064A: 0x06CC, // ي → ی
    0x0649: 0x06CC, // ى → ی
    0x0626: 0x06CC, // ئ → ی
    0x0643: 0x06A9, // ك → ک
    0x0623: 0x0627, // أ → ا
    0x0625: 0x0627, // إ → ا
    0x0622: 0x0627, // آ → ا
    0x0671: 0x0627, // ٱ → ا
    0x0621: 0x0627, // ء → ا
    0x0629: 0x0647, // ة → ه
    0x06C0: 0x0647, // ۀ → ه
    0x0624: 0x0648, // ؤ → و
  };

  /// Code points dropped entirely before matching: the zero-width joiners, the
  /// bidi marks, tatweel, the Arabic diacritics (harakat) and the BOM. None of
  /// them change which name is meant, and every one of them is invisible, so a
  /// user can never tell they are the reason a search came back empty.
  static bool _isIgnorable(int c) {
    if (c >= 0x064B && c <= 0x0652) return true; // harakat
    if (c >= 0x200B && c <= 0x200F) return true; // ZWSP…RLM
    if (c >= 0x202A && c <= 0x202E) return true; // bidi embedding/override
    return c == 0x0640 || c == 0x0670 || c == 0xFEFF; // tatweel, superscript alef, BOM
  }

  /// Persian (۰–۹) and Arabic-Indic (٠–٩) digit block starts.
  static const int _persianZero = 0x06F0;
  static const int _arabicZero = 0x0660;
  static const int _asciiZero = 0x30;

  static final RegExp _whitespace = RegExp(r'\s+');

  /// Canonical form of a searchable string: Persian/Arabic digits → ASCII,
  /// Arabic letter variants → Persian, ignorable marks removed, lowercased,
  /// runs of whitespace collapsed to one space.
  static String fold(String input) {
    if (input.isEmpty) return '';
    final buffer = StringBuffer();
    for (final c in input.runes) {
      if (_isIgnorable(c)) continue;
      buffer.writeCharCode(_canonical(c));
    }
    return buffer
        .toString()
        .toLowerCase()
        .replaceAll(_whitespace, ' ')
        .trim();
  }

  /// [fold] with every space removed — «محمدرضا» has to find «محمد رضا».
  static String foldTight(String input) => fold(input).replaceAll(' ', '');

  /// Digits of [input], Persian/Arabic numerals included, everything else
  /// stripped.
  static String digits(String input) {
    final buffer = StringBuffer();
    for (final c in input.runes) {
      final canonical = _canonical(c);
      if (canonical >= _asciiZero && canonical <= _asciiZero + 9) {
        buffer.writeCharCode(canonical);
      }
    }
    return buffer.toString();
  }

  /// True when the folded [haystack] contains the folded [needle], tolerating
  /// the writing differences [fold] normalises away plus optional spacing.
  ///
  /// Both sides are folded exactly once: this runs per contact per keystroke,
  /// and folding the same name four times (twice here, twice in `foldTight`)
  /// is address-book-sized garbage for nothing.
  static bool nameContains(String haystack, String needle) {
    final query = fold(needle);
    if (query.isEmpty) return true;
    final name = fold(haystack);
    if (name.contains(query)) return true;
    if (!query.contains(' ') && !name.contains(' ')) return false;
    return name.replaceAll(' ', '').contains(query.replaceAll(' ', ''));
  }

  /// The range of [haystack] that matches [needle] **in the original string's
  /// indices**, or null when it does not match.
  ///
  /// Highlighting a search hit needs the position in the text actually being
  /// painted, not in the folded copy — folding drops characters (ZWNJ,
  /// harakat), so an index taken on the folded string lands on the wrong letter.
  static (int, int)? matchRange(String haystack, String needle) {
    final query = fold(needle);
    if (query.isEmpty || haystack.isEmpty) return null;

    final buffer = StringBuffer();
    final positions = <int>[];
    for (var i = 0; i < haystack.length; i++) {
      final c = haystack.codeUnitAt(i);
      if (_isIgnorable(c)) continue;
      final canonical = String.fromCharCode(_canonical(c)).toLowerCase();
      if (canonical.length != 1) continue;
      buffer.write(canonical);
      positions.add(i);
    }

    final at = buffer.toString().indexOf(query);
    if (at < 0 || at + query.length > positions.length) return null;
    return (positions[at], positions[at + query.length - 1] + 1);
  }

  /// True when [number] (as stored in the address book) matches the digits of
  /// [query] in any equivalent form — see [phoneMatch].
  static bool phoneContains(String number, String query) =>
      phoneMatch(number, query) != null;

  /// Where [query] matches [number], or null when it does not.
  ///
  /// Both sides are expanded into every way the same number gets written, so a
  /// contact saved as `+98 912 123 4567` is found by `09121234567`,
  /// `9121234567`, `989121234567`, `+98912` and `1234567` alike — the old raw
  /// substring test found only the last of those.
  ///
  /// The digits **as typed** match anywhere in the number (dialing the middle
  /// of a number is a normal way to find it), but a form derived by stripping a
  /// trunk `0` or a `98` country code only matches at the **start**: those
  /// digits are a prefix convention, not content. Without that asymmetry,
  /// searching `021…` for a landline also returned every mobile that happens to
  /// contain `21`.
  static PhoneHit? phoneMatch(String number, String query) =>
      PhoneQuery(query).match(number);

  /// The digit strings [number] may be searched against: its raw digits, its
  /// national `09…` form, and that form without the trunk `0` (so a query
  /// written with the `98` country code lines up). Duplicates are dropped.
  ///
  /// Memoized: filtering an address book asks for the forms of the same numbers
  /// again on every keystroke, and normalizing them each time is the bulk of
  /// the work a search does.
  static List<String> phoneForms(String number) {
    final cached = _formsCache[number];
    if (cached != null) return cached;

    final raw = digits(number);
    if (raw.isEmpty) return const [];
    final forms = <String>[raw];
    final national = digits(PhoneNormalizer.toNational(number));
    _addForm(forms, national);
    if (national.length > 1 && national.startsWith('0')) {
      _addForm(forms, national.substring(1));
    }
    // A plain cap, not an LRU: the keys are the phone numbers on the device, so
    // the map converges on the address book and stops growing. The clear only
    // ever fires on a pathological book and just costs one re-normalization.
    if (_formsCache.length >= _maxCachedForms) _formsCache.clear();
    _formsCache[number] = forms;
    return forms;
  }

  static const int _maxCachedForms = 8192;
  static final Map<String, List<String>> _formsCache = {};

  // ── T9 (name-by-digits) ──────────────────────────────────────────────────

  /// The Persian keypad's letter groups, in the layout Iranian phones have used
  /// since the feature-phone era: 32 letters over the keys `۲`–`۹`.
  ///
  /// Written as one string per key rather than a `Map<int,int>` so the table is
  /// readable against a physical keypad — which is the only way to check it.
  static const Map<String, String> _t9Groups = {
    '2': 'ابپتث',
    '3': 'جچحخ',
    '4': 'دذرزژ',
    '5': 'سشصض',
    '6': 'طظعغ',
    '7': 'فقکگ',
    '8': 'لمنو',
    '9': 'هی',
  };

  /// Folded letter → keypad digit, built once from [_t9Groups] plus the latin
  /// groups printed on the keys themselves.
  ///
  /// Derived from the table above rather than written out again: a second copy
  /// is a second thing to keep in step, and a wrong entry here does not fail —
  /// it silently stops finding one letter's contacts.
  static final Map<int, int> _t9 = () {
    final map = <int, int>{};
    for (final entry in _t9Groups.entries) {
      final digit = entry.key.codeUnitAt(0);
      // Fold each letter first: the table is written in canonical Persian, and
      // a name stored with «ك» or «ي» has to land on the same key.
      for (final letter in entry.value.runes) {
        map[_canonical(letter)] = digit;
      }
    }
    const latin = ['abc', 'def', 'ghi', 'jkl', 'mno', 'pqrs', 'tuv', 'wxyz'];
    for (var i = 0; i < latin.length; i++) {
      final digit = _asciiZero + 2 + i;
      for (final letter in latin[i].runes) {
        map[letter] = digit;
      }
    }
    return map;
  }();

  /// Shortest query T9 answers. One digit is a third of the address book — the
  /// dialer's number suggestions are the useful answer at that length.
  static const int minT9Length = 2;

  /// [name] compiled to keypad digits. Memoized per name string.
  static T9Name t9Of(String name) {
    final cached = _t9Cache[name];
    if (cached != null) return cached;

    final digits = StringBuffer();
    final positions = <int>[];
    final wordStarts = <int>[];
    var atWordStart = true;

    for (var i = 0; i < name.length; i++) {
      final c = name.codeUnitAt(i);
      if (_isIgnorable(c)) continue;
      var canonical = _canonical(c);
      if (canonical >= 0x41 && canonical <= 0x5A) canonical += 0x20; // A–Z
      // A digit inside a name types itself.
      final isDigit = canonical >= _asciiZero && canonical <= _asciiZero + 9;
      final key = _t9[canonical] ?? (isDigit ? canonical : -1);
      if (key < 0) {
        // Space, punctuation, or a script with no key: not a letter, so the
        // next one that is starts a new word.
        atWordStart = true;
        continue;
      }
      if (atWordStart) {
        wordStarts.add(digits.length);
        atWordStart = false;
      }
      digits.writeCharCode(key);
      positions.add(i);
    }

    final built = T9Name(digits.toString(), positions, wordStarts);
    if (_t9Cache.length >= _maxCachedForms) _t9Cache.clear();
    _t9Cache[name] = built;
    return built;
  }

  static final Map<String, T9Name> _t9Cache = {};

  /// Where the keypad digits [query] match [name], **in the original string's
  /// indices**, or null.
  ///
  /// Matches from a word start only, and prefers the earliest word — «۷۲۴»
  /// finds «کبری رضایی» on the first name, not somewhere inside the surname.
  static (int, int)? t9MatchRange(String name, String query) {
    if (query.length < minT9Length) return null;
    final t9 = t9Of(name);
    if (t9.isEmpty) return null;
    for (final start in t9.wordStarts) {
      if (start + query.length > t9.digits.length) continue;
      if (!t9.digits.startsWith(query, start)) continue;
      return (
        t9.positions[start],
        t9.positions[start + query.length - 1] + 1,
      );
    }
    return null;
  }

  /// The digit strings a typed [query] may mean.
  ///
  /// The user does not tell the search which prefix convention they are using:
  /// `0912`, `912`, `98912` and `+98912` are the same intent, so each is tried.
  /// Stripping the trunk `0` / the `98` country code is what lets a query
  /// written one way find a number stored the other way.
  static List<String> queryForms(String query) {
    final q = digits(query);
    if (q.isEmpty) return const [];
    final forms = <String>[q];
    var trimmed = q;
    if (trimmed.startsWith('00') && trimmed.length > 2) {
      trimmed = trimmed.substring(2);
      _addForm(forms, trimmed);
    }
    if (trimmed.startsWith('98') && trimmed.length > 2) {
      _addForm(forms, trimmed.substring(2));
    } else if (trimmed.startsWith('0') && trimmed.length > 1) {
      _addForm(forms, trimmed.substring(1));
    }
    _addForm(forms, digits(PhoneNormalizer.toNational(q)));
    return forms;
  }

  static void _addForm(List<String> forms, String value) {
    if (value.isNotEmpty && !forms.contains(value)) forms.add(value);
  }

  /// Folds one code point: eastern digits become ASCII, Arabic letter variants
  /// become their Persian equivalent, everything else passes through.
  static int _canonical(int c) {
    if (c >= _persianZero && c <= _persianZero + 9) {
      return _asciiZero + (c - _persianZero);
    }
    if (c >= _arabicZero && c <= _arabicZero + 9) {
      return _asciiZero + (c - _arabicZero);
    }
    return _letterFolds[c] ?? c;
  }
}
