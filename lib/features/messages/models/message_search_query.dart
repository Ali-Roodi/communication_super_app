import 'package:communication_super_app/core/utils/search_text.dart';

/// A message-body search compiled once: the SQL prefilter that narrows the scan
/// plus the authoritative Dart matcher that decides.
///
/// ## Why two stages
///
/// `SearchText` is the app's ONE matcher (see CLAUDE.md → «Contact search») and
/// SQL cannot be it: `LIKE` has no idea that ي ≡ ی, that a ZWNJ or a harakat is
/// invisible, or that «۵» is `5`, and this database carries no FTS5/ICU table to
/// fold for it. So a body search runs:
///
///  1. **Prefilter in SQLite** — an AND over a few characters of the *folded*
///     query, each expanded into every character that folds onto it
///     (`body LIKE '%ی%' OR body LIKE '%ي%' …`). Only rows carrying all of those
///     characters cross the platform channel.
///  2. **Decide in Dart** — `SearchText.nameContains` on the survivors, which is
///     the same call every other search in the app makes.
///
/// The prefilter is deliberately *widening*: it may pass rows stage 2 then drops
/// (a wrong-order or wrong-form hit), but it must never drop a row stage 2 would
/// have accepted. That is the only property it needs.
///
/// ## Why it has no false negatives
///
/// A folded match requires every non-space character of the folded query to be
/// present in the folded body — `nameContains` only ever makes *spacing*
/// optional, never a letter or a digit. So for any one such character, "the body
/// contains some character that folds onto it" is implied by a match, and an AND
/// of several of those is still implied. Two details keep that airtight:
///
///  - The pre-image sets are **derived from `SearchText.fold` at runtime**
///    (`_preimages`), not copied out of its private fold tables. A copy would be
///    a second source of truth whose failure mode is a search that silently
///    stops finding messages.
///  - SQLite's `LIKE` is case-insensitive for ASCII only, so every term also
///    ORs in `toUpperCase()` of the character — that is what keeps a query typed
///    in lower-case Cyrillic/Greek from missing an upper-case body.
///
/// ## The bound, and what it costs
///
/// `LIKE '%x%'` is **not** indexable — no prefilter over message bodies is
/// without an FTS index — so the prefilter is a scan. It is made survivable, not
/// free: the scan runs newest-first over `idx_messages_timestamp`, and both the
/// SQL page size and the number of prefiltered rows examined in Dart are capped
/// in [MessageRepository.searchMessages]. A one-letter query on a full mailbox
/// therefore searches the most recent N messages instead of freezing the UI on
/// all of them. A query that folds to nothing at all (only ZWNJ/harakat) builds
/// no prefilter and matches everything, which is the *same* bounded newest-first
/// scan — the honest answer for a query that has no content.
class MessageSearchQuery {
  MessageSearchQuery(String query)
    : raw = query.trim(),
      folded = SearchText.fold(query),
      phone = PhoneQuery(query) {
    _terms = _buildTerms(folded);
  }

  /// The query as typed (trimmed). Stage 2 folds it itself.
  final String raw;

  /// [SearchText.fold] of the query — what the prefilter is built from.
  final String folded;

  /// Digit forms of the query, compiled once (see [PhoneQuery]) — the number
  /// half of a thread search.
  final PhoneQuery phone;

  /// One entry per prefilter term; each entry is the set of `LIKE` patterns
  /// that may satisfy it (OR), and the terms are AND-ed.
  late final List<List<String>> _terms;

  bool get isEmpty => raw.isEmpty;

  /// The query in the space **stripped** folded space the FTS index is built in.
  ///
  /// Whitespace goes because `SearchText.nameContains` treats spacing as
  /// optional («محمدرضا» finds «محمد رضا»), and a substring test over
  /// space-stripped text is a provable *superset* of that rule: if the query
  /// occurs contiguously with spaces, it still occurs once the same spaces are
  /// deleted from both sides. So the index can only ever be too generous, and
  /// [matchesBody] settles it — the same contract the `LIKE` prefilter has.
  late final String tight = SearchText.foldTight(raw);

  /// True when the FTS index can answer this query at all.
  ///
  /// The trigram tokenizer indexes three-character windows, so it simply cannot
  /// speak about a one- or two-character needle; those fall back to the scan.
  bool get canUseFts => tight.length >= 3;

  /// The `MATCH` argument for a trigram substring search. A quoted phrase is
  /// what makes FTS5 match the string *inside* a token rather than as a token;
  /// embedded quotes are doubled, which is the only escape the syntax has.
  String get ftsMatch => '"${tight.replaceAll('"', '""')}"';

  /// True when the query carries digits worth matching against a phone number.
  bool get hasDigits => !phone.isEmpty;

  /// The `WHERE` fragment for the prefilter, or null when the query folds to
  /// nothing and every row is a candidate.
  String? get bodyWhere {
    if (_terms.isEmpty) return null;
    return _terms
        .map(
          (patterns) =>
              '(${patterns.map((_) => "body LIKE ? ESCAPE '\\'").join(' OR ')})',
        )
        .join(' AND ');
  }

  /// Bind values for [bodyWhere], in the same order.
  List<Object?> get bodyArgs => [
    for (final term in _terms)
      for (final pattern in term) pattern,
  ];

  /// The authoritative test — identical to what the contacts list, the dialer
  /// and `SearchBloc` use for names.
  bool matchesBody(String body) => SearchText.nameContains(body, raw);

  // ── Prefilter construction ──────────────────────────────────────────────

  /// How many characters of the query become AND-ed terms. More terms means a
  /// more selective prefilter and more `LIKE` tests per row; four is enough to
  /// cut a Persian word down to a handful of rows.
  static const int _kPrefilterTerms = 4;

  static List<List<String>> _buildTerms(String folded) {
    final terms = <List<String>>[];
    final seen = <String>{};
    // By rune, not by code unit: slicing an emoji in half would bind a lone
    // surrogate as a LIKE pattern, which matches nothing — a false negative
    // manufactured by the prefilter itself.
    for (final rune in folded.runes) {
      if (terms.length >= _kPrefilterTerms) break;
      final ch = String.fromCharCode(rune);
      // Spacing is optional in a folded match, so a space proves nothing.
      if (ch == ' ' || !seen.add(ch)) continue;
      terms.add(_patternsFor(ch));
    }
    return terms;
  }

  static List<String> _patternsFor(String ch) {
    // Every branch added here only widens the term, so being generous is free
    // in correctness and cheap in work (one extra LIKE per row).
    final variants = <String>{ch, ch.toUpperCase(), ...?_preimages[ch]};
    return [for (final v in variants) '%${_escapeLike(v)}%'];
  }

  /// `%`, `_` and the escape character itself are wildcards in a LIKE pattern.
  /// Every pattern is emitted with `ESCAPE '\'`, so they are escaped here.
  static String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  /// folded character → every character `SearchText.fold` turns into it.
  ///
  /// Built once, lazily, on the first search of the session (~14 k one-character
  /// folds, a couple of milliseconds) and never rebuilt.
  static Map<String, Set<String>> get _preimages =>
      _preimagesCache ??= _derivePreimages();
  static Map<String, Set<String>>? _preimagesCache;

  static Map<String, Set<String>> _derivePreimages() {
    final map = <String, Set<String>>{};

    void scan(int from, int to) {
      for (var c = from; c <= to; c++) {
        final source = String.fromCharCode(c);
        final folded = SearchText.fold(source);
        if (folded.isEmpty || folded == source) continue;
        // A fold that yields more than one character (İ → i + ̇ ) still means
        // the source may stand in for each of them; widening is safe.
        for (final rune in folded.runes) {
          map
              .putIfAbsent(String.fromCharCode(rune), () => <String>{})
              .add(source);
        }
      }
    }

    // Everything up to U+2FFF: the Latin/Greek/Cyrillic case pairs, the Arabic
    // and Persian letter variants, both eastern digit blocks and the letterlike
    // symbols (U+212A KELVIN SIGN folds to `k`). U+FB00–U+FEFF adds the Arabic
    // presentation forms and ligatures. Nothing above that folds onto a
    // character a Persian message search would be typed with.
    scan(0x0000, 0x2FFF);
    scan(0xFB00, 0xFEFF);
    return map;
  }
}
