import 'package:equatable/equatable.dart';

/// The four ways a number meets this phone, each with its own [ListMode].
/// The keys are the native ones (`NumberListRules.Channel`).
enum ListChannel {
  smsIn('sms_in', 'پیامک‌های دریافتی'),
  smsOut('sms_out', 'پیامک‌های ارسالی'),
  callIn('call_in', 'تماس‌های ورودی'),
  callOut('call_out', 'تماس‌های خروجی');

  const ListChannel(this.key, this.label);
  final String key;
  final String label;
}

/// To whom a [ListChannel] is open — the matrix's «همه / موردی / به‌جز».
enum ListMode {
  /// «موردی»: everybody except a number on the black list. The default.
  blacklist('blacklist', 'همه، به‌جز فهرست سیاه'),

  /// «به‌جز»: nobody except a number on the white list.
  whitelist('whitelist', 'فقط فهرست سفید'),

  /// «همه»: nobody at all.
  nobody('nobody', 'هیچ‌کس');

  const ListMode(this.key, this.label);
  final String key;
  final String label;

  /// An unknown or missing key is the default, never a restriction.
  static ListMode of(String? key) => ListMode.values.firstWhere(
    (m) => m.key == key,
    orElse: () => ListMode.blacklist,
  );
}

/// «فهرست سیاه و سفید» (matrix row 10, every edition): the configuration.
///
/// Decided natively (`NumberListRules` / `NumberLists` in Kotlin), where every
/// receive, send and call path asks — most of them run with no Flutter engine.
/// Dart owns the setting and mirrors it there as one set
/// (`NumberListsBridge.mirror`), and asks the same native question before a
/// send or a call so a refusal leaves nothing behind.
///
/// Separate from «هرزنامه و مسدودشده» (`blocked_numbers`): that is a list of
/// exact numbers the user blocked from a conversation, synced with the
/// phone's own list, and it is checked first whatever the mode here.
class NumberLists extends Equatable {
  final Map<ListChannel, ListMode> modes;

  /// Entries in the form [normalizePattern] produces.
  final List<String> black;
  final List<String> white;

  /// In [ListMode.whitelist], a saved contact is allowed too.
  final bool contactsAllowed;

  const NumberLists({
    this.modes = const {},
    this.black = const [],
    this.white = const [],
    this.contactsAllowed = false,
  });

  ListMode modeOf(ListChannel channel) => modes[channel] ?? ListMode.blacklist;

  /// How many channels are restricted beyond the default with an empty black
  /// list — what the settings row counts.
  int get activeChannels => ListChannel.values
      .where((c) => modeOf(c) != ListMode.blacklist || black.isNotEmpty)
      .length;

  NumberLists copyWith({
    Map<ListChannel, ListMode>? modes,
    List<String>? black,
    List<String>? white,
    bool? contactsAllowed,
  }) => NumberLists(
    modes: modes ?? this.modes,
    black: black ?? this.black,
    white: white ?? this.white,
    contactsAllowed: contactsAllowed ?? this.contactsAllowed,
  );

  NumberLists withMode(ListChannel channel, ListMode mode) =>
      copyWith(modes: Map.unmodifiable({...modes, channel: mode}));

  /// [list] with [input] added, normalised, without duplicates; null when
  /// [input] is not a usable entry.
  static List<String>? add(List<String> list, String input) {
    final normalized = normalizePattern(input);
    if (normalized == null) return null;
    if (list.contains(normalized)) return list;
    return List.unmodifiable([...list, normalized]);
  }

  /// Keeps the usable entries of [stored], normalised, once each.
  static List<String> clean(Iterable<String> stored) {
    final out = <String>[];
    for (final e in stored) {
      final n = normalizePattern(e);
      if (n != null && !out.contains(n)) out.add(n);
    }
    return List.unmodifiable(out);
  }

  static const int _minSubscriberDigits = 7;
  static const int _minPatternDigits = 3;
  static const int _maxPatternLength = 20;

  /// An entry as typed (`+98 912 *`, `۰۹۱۲۱۲۳۴۵۶۷`, `*1234`) in the national
  /// form numbers are compared in (`0912*`, `09121234567`); null when it is not
  /// usable. `*` is any run of digits, `?` (or `؟`) exactly one.
  ///
  /// **Mirrors `NumberListRules.normalizePattern` in Kotlin**, which
  /// re-normalises whatever it is handed — change the two together;
  /// `NumberListRulesTest` and `number_lists_test.dart` share their vectors.
  static String? normalizePattern(String input) {
    final out = StringBuffer();
    var plus = false;
    for (final rune in input.trim().runes) {
      final d = _digitValue(rune);
      if (d != null) {
        out.write(d);
      } else if (rune == 0x2A) {
        // `*`, collapsed: `**` means nothing more than `*`.
        if (!out.toString().endsWith('*')) out.write('*');
      } else if (rune == 0x3F || rune == 0x061F) {
        out.write('?');
      } else if (rune == 0x2B && out.isEmpty && !plus) {
        plus = true;
      } else if (_isSeparator(rune)) {
        continue;
      } else {
        return null;
      }
    }
    final s = out.toString();
    final String national;
    if (plus) {
      if (!s.startsWith('98')) return null;
      national = '0${s.substring(2)}';
    } else if (s.startsWith('0098')) {
      national = '0${s.substring(4)}';
    } else if (s.startsWith('00')) {
      return null;
    } else if (s.startsWith('98')) {
      national = '0${s.substring(2)}';
    } else if (s.startsWith('9')) {
      national = '0$s';
    } else {
      national = s;
    }
    final digitCount = national.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digitCount < _minPatternDigits || national.length > _maxPatternLength) {
      return null;
    }
    if (!national.startsWith('0') &&
        !national.startsWith('*') &&
        !national.startsWith('?')) {
      return null;
    }
    final wildcard = national.contains('*') || national.contains('?');
    if (!wildcard && digitCount < _minSubscriberDigits) return null;
    return national;
  }

  /// ASCII, Persian (۰–۹) and Arabic-Indic (٠–٩) digits.
  static int? _digitValue(int rune) {
    if (rune >= 0x30 && rune <= 0x39) return rune - 0x30;
    if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0;
    if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660;
    return null;
  }

  static bool _isSeparator(int rune) =>
      rune == 0x20 ||
      rune == 0x2D || // -
      rune == 0x28 ||
      rune == 0x29 ||
      rune == 0x2E ||
      rune == 0xA0 ||
      rune == 0x200C ||
      rune == 0x200E ||
      rune == 0x200F ||
      (rune >= 0x202A && rune <= 0x202E) ||
      (rune >= 0x2066 && rune <= 0x2069);

  /// Modes compared as the native mirror sees them: a channel left out of
  /// [modes] equals one set to the default.
  @override
  List<Object?> get props => [
    ListChannel.values.map(modeOf).toList(),
    black,
    white,
    contactsAllowed,
  ];
}
