import 'package:equatable/equatable.dart';

/// A reusable message template («قالب آماده»).
///
/// [body] is plain text with `[...]` placeholders — «جلسه [عنوان] در مورخه
/// [تاریخ] ساعت [زمان] برقرار می‌باشد.». The placeholders are what turn a
/// template into a small form: [TemplateEngine] derives one input field per
/// placeholder, and [TemplateEngine.render] substitutes the answers back in.
///
/// [useContactName] prefixes the rendered text with «<نام> عزیز» when the
/// template is used inside a conversation with a known contact (the Figma
/// «درج نام مخاطب» switch). It is only a *default*: the fill screen still lets
/// the user turn it off per use.
class MessageTemplate extends Equatable {
  final String id;
  final String title;
  final String body;
  final bool useContactName;

  /// Pinned templates sort above the rest, independent of [updatedAt].
  final bool isPinned;
  final DateTime updatedAt;

  MessageTemplate({
    required this.id,
    required this.title,
    required this.body,
    this.useContactName = false,
    this.isPinned = false,
    required this.updatedAt,
  });

  /// The form this template asks for, parsed once per instance — the picker
  /// calls this per card to decide whether a tap needs the fill screen at all.
  late final List<TemplateField> fields = TemplateEngine.fieldsOf(body);

  /// True when tapping the template must open the fill screen: it either has
  /// placeholders to answer or a contact name to offer.
  bool needsInput({bool hasContactName = false}) =>
      fields.isNotEmpty || (useContactName && hasContactName);

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'body': body,
    'use_contact_name': useContactName ? 1 : 0,
    'is_pinned': isPinned ? 1 : 0,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory MessageTemplate.fromMap(Map<String, dynamic> map) => MessageTemplate(
    id: map['id'] as String,
    title: map['title'] as String,
    body: map['body'] as String,
    useContactName: ((map['use_contact_name'] as int?) ?? 0) == 1,
    isPinned: ((map['is_pinned'] as int?) ?? 0) == 1,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
  );

  @override
  List<Object?> get props => [
    id,
    title,
    body,
    useContactName,
    isPinned,
    updatedAt,
  ];
}

/// What a template's fill screen renders for one placeholder.
enum TemplateFieldKind {
  /// Single-line text.
  text,

  /// Multi-line text («توضیحات»).
  multiline,

  /// Date only, picked on the user's calendar (Jalali by default).
  date,

  /// Time of day only.
  time,

  /// One picker feeding a date *and* a time. Either a single placeholder that
  /// asks for both, or the merged «تاریخ» + «زمان» pair (see [TemplateEngine]).
  dateTime,
}

/// One input of a template's generated form.
class TemplateField extends Equatable {
  /// Label shown above the input — «تاریخ و زمان» for a merged pair.
  final String label;

  /// The placeholder name(s) this input fills. A merged date/time pair carries
  /// two: the date placeholder first, the time placeholder second.
  final List<String> tokens;

  final TemplateFieldKind kind;

  const TemplateField({
    required this.label,
    required this.tokens,
    required this.kind,
  });

  /// Stable key for the field's value in the answer map / state.
  String get key => tokens.first;

  bool get isDateLike =>
      kind == TemplateFieldKind.date ||
      kind == TemplateFieldKind.time ||
      kind == TemplateFieldKind.dateTime;

  @override
  List<Object?> get props => [label, tokens, kind];
}

/// Placeholder parsing and substitution for [MessageTemplate].
///
/// Deliberately string-only: the fill screen formats a picked [DateTime] into
/// the answer map, so a template body never has to encode a value *type* and a
/// user-authored template gets the same behaviour as a built-in one.
abstract class TemplateEngine {
  /// `[...]` — no newline inside, capped so an unmatched bracket in a long
  /// message body can't swallow half the text as one "placeholder".
  static final RegExp placeholder = RegExp(r'\[([^\[\]\n]{1,40})\]');

  static final RegExp _spaceBeforePunctuation = RegExp(r' +([.،؛:!؟])');
  static final RegExp _runOfSpaces = RegExp(r'[ \t]{2,}');

  /// Distinct placeholder names, in the order they appear.
  static List<String> tokensOf(String body) {
    final names = <String>[];
    for (final m in placeholder.allMatches(body)) {
      final name = m.group(1)!.trim();
      if (name.isEmpty || names.contains(name)) continue;
      names.add(name);
    }
    return names;
  }

  /// The form for [body]: one field per placeholder, except that a date
  /// placeholder and a time placeholder collapse into a single «تاریخ و زمان»
  /// picker (Figma) — asking for them separately means two pickers for one
  /// moment.
  static List<TemplateField> fieldsOf(String body) {
    final fields = [
      for (final name in tokensOf(body))
        TemplateField(label: name, tokens: [name], kind: _kindOf(name)),
    ];

    // Merge the first date-only field with the first time-only one, in the
    // date's place; the pair describes a single moment. A lone date or a lone
    // time keeps its own picker.
    final dateAt = fields.indexWhere((f) => f.kind == TemplateFieldKind.date);
    final timeAt = fields.indexWhere((f) => f.kind == TemplateFieldKind.time);
    if (dateAt >= 0 && timeAt >= 0) {
      final date = fields[dateAt];
      final time = fields[timeAt];
      fields[dateAt] = TemplateField(
        label: '${date.label} و ${time.label}',
        tokens: [date.tokens.first, time.tokens.first],
        kind: TemplateFieldKind.dateTime,
      );
      fields.removeAt(timeAt);
    }
    return fields;
  }

  static TemplateFieldKind _kindOf(String label) {
    final hasDate = label.contains('تاریخ') || label.contains('مورخ');
    final hasTime =
        label.contains('ساعت') ||
        label.contains('زمان') ||
        label.contains('وقت');
    if (hasDate && hasTime) return TemplateFieldKind.dateTime;
    if (hasDate) return TemplateFieldKind.date;
    if (hasTime) return TemplateFieldKind.time;
    if (label.contains('توضیح') ||
        label.contains('متن') ||
        label.contains('آدرس') ||
        label.contains('نشانی') ||
        label.contains('پیام')) {
      return TemplateFieldKind.multiline;
    }
    return TemplateFieldKind.text;
  }

  /// Substitutes [values] (keyed by placeholder name) into [body].
  ///
  /// With [preview] = true an unanswered placeholder is kept as `[نام]` so the
  /// live preview reads like the template; with false it is dropped and the
  /// leftover spacing tidied, so an unfilled «[توضیحات]» never ships inside a
  /// real SMS.
  static String render(
    String body, {
    Map<String, String> values = const {},
    String? contactName,
    bool useContactName = false,
    bool preview = false,
  }) {
    var filled = '';
    var cursor = 0;
    for (final m in placeholder.allMatches(body)) {
      filled += body.substring(cursor, m.start);
      cursor = m.end;
      final value = values[m.group(1)!.trim()]?.trim() ?? '';
      if (value.isNotEmpty) {
        filled += value;
      } else if (preview) {
        filled += m.group(0)!;
      } else {
        // Dropping the placeholder alone would leave the preposition that
        // introduced it stranded — «در محل برقرار می‌باشد.».
        filled = _dropDanglingConnector(filled);
      }
    }
    filled += body.substring(cursor);

    final text = tidy(filled);
    final name = contactName?.trim();
    if (!useContactName || name == null || name.isEmpty) return text;
    return text.isEmpty ? '$name عزیز' : '$name عزیز\n$text';
  }

  /// Prepositions that only exist to introduce a placeholder. Longest first, so
  /// «در مورخه» is taken over the «در» inside it.
  static const _connectors = [
    'در مورخه',
    'در تاریخ',
    'در ساعت',
    'در محل',
    'مورخه',
    'ساعت',
    'بابت',
    'برای',
    'مبلغ',
    'در',
    'به',
    'از',
    'با',
  ];

  /// Removes the preposition [text] ends with, when the placeholder it
  /// introduced was dropped. Only an exact trailing word is taken, and only
  /// when it stands on its own («…در محل» → «…», but «…مدیر» stays).
  static String _dropDanglingConnector(String text) {
    final trimmed = text.replaceFirst(RegExp(r'[ \t]+$'), '');
    for (final word in _connectors) {
      if (!trimmed.endsWith(word)) continue;
      final at = trimmed.length - word.length;
      if (at > 0 && !RegExp(r'[\s\n]').hasMatch(trimmed[at - 1])) continue;
      return trimmed.substring(0, at);
    }
    return text;
  }

  /// Collapses the gaps a dropped placeholder leaves behind: doubled spaces, a
  /// space before punctuation, and lines that became empty.
  static String tidy(String input) {
    final out = <String>[];
    for (final raw in input.split('\n')) {
      final line = raw
          .replaceAll(_runOfSpaces, ' ')
          .replaceAllMapped(_spaceBeforePunctuation, (m) => m.group(1)!)
          .trim();
      if (line.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
      out.add(line);
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out.join('\n');
  }
}
