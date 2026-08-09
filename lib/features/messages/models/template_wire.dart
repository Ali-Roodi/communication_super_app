import 'built_in_templates.dart';
import 'message_template_model.dart';

/// The over-the-air format for a **built-in** template.
///
/// A filled template is mostly boilerplate the receiver already has: «جلسه … در
/// مورخه … ساعت … در محل … برقرار می‌باشد.» costs ~110 UCS-2 characters before
/// the user types anything, and Persian SMS fits 70 characters per part. So a
/// built-in template does not ship its prose — it ships a short header naming
/// the template plus the answers the user typed:
///
/// ```text
/// [#T1:mtg:1]علی|جلسه هفتگی|۱۴۰۵/۰۵/۲۰|۱۰:۳۰|اتاق ۳
/// ```
///
/// * `#T1` — this format, version 1.
/// * `mtg` — [BuiltInTemplate.code]; the receiver looks the body up in its own
///   compiled-in catalogue, so nothing about the wording travels.
/// * `1` — flag bits. Bit 0: the first payload segment is the «<نام> عزیز»
///   greeting the sender addressed (it names the *recipient*, so the receiver
///   cannot re-derive it from its own address book).
/// * the rest — one segment per placeholder, in [BuiltInTemplate.tokens] order.
///
/// A receiver running this app rebuilds the full message and can show the
/// answers back in the template's own inputs. A receiver that does not have the
/// app sees the header and the answers as plain text — a few disconnected words,
/// which is the accepted trade.
///
/// Templates the user wrote themselves are **never** encoded: there is no
/// backend, so the other phone has no way to know their body. Neither is a
/// built-in whose body the user edited — see [BuiltInTemplates.of].
///
/// The format is also the seam the next phase (encrypted SMS) plugs into: the
/// payload after the header is already a self-contained, prose-free field list.
abstract class TemplateWire {
  /// Bumped only for a change that older builds cannot parse. An unknown
  /// version decodes to null, so such a message renders as its raw text
  /// instead of as a wrong reconstruction.
  static const int version = 1;

  /// Cheap pre-test before the regex — this runs per rendered bubble and per
  /// inbox row.
  static const String sigil = '[#T';

  static final RegExp _header = RegExp(r'^\[#T(\d{1,2}):([a-z0-9]{2,6}):(\d{1,3})\]');

  static const int _flagGreeting = 1;

  /// Encodes [template] filled with [values], or returns null when the compact
  /// format does not apply — the caller then sends the rendered text as usual.
  ///
  /// Returns null when the template is not a pristine built-in, when it has no
  /// placeholders (nothing to compress), or when the encoded form would not
  /// actually be shorter than the prose. That last guard matters: a template
  /// with one placeholder and a long answer gains nothing from the header, and
  /// shipping an unreadable payload to save no SMS parts is a pure loss.
  static String? encode({
    required MessageTemplate template,
    required Map<String, String> values,
    String? greetingName,
    required String renderedText,
  }) {
    final builtIn = BuiltInTemplates.of(template);
    if (builtIn == null || !builtIn.isFillable) return null;

    final greeting = greetingName?.trim() ?? '';
    final flags = greeting.isEmpty ? 0 : _flagGreeting;

    final segments = <String>[
      if (greeting.isNotEmpty) greeting,
      for (final token in builtIn.tokens) values[token]?.trim() ?? '',
    ];
    // Trailing blanks carry no information — «…|اتاق ۳||» is «…|اتاق ۳».
    while (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    if (segments.isEmpty) return null;

    final encoded =
        '[#T$version:${builtIn.code}:$flags]${segments.map(_escape).join('|')}';
    return encoded.length < renderedText.length ? encoded : null;
  }

  /// Parses [body] as a wire payload, or returns null when it is ordinary text
  /// (including a payload from a newer format version, or one naming a template
  /// this build does not know).
  static TemplateWireMessage? decode(String body) {
    if (!body.startsWith(sigil)) return null;
    final match = _header.matchAsPrefix(body);
    if (match == null) return null;
    if (int.parse(match.group(1)!) != version) return null;

    final builtIn = BuiltInTemplates.byCode(match.group(2)!);
    if (builtIn == null) return null;

    final flags = int.parse(match.group(3)!);
    final segments = _split(body.substring(match.end));

    var at = 0;
    String? greeting;
    if (flags & _flagGreeting != 0 && segments.isNotEmpty) {
      greeting = segments[at++];
    }

    final values = <String, String>{};
    for (final token in builtIn.tokens) {
      if (at >= segments.length) break;
      final value = segments[at++];
      if (value.isNotEmpty) values[token] = value;
    }

    return TemplateWireMessage(
      template: builtIn,
      values: values,
      greetingName: (greeting == null || greeting.isEmpty) ? null : greeting,
    );
  }

  /// What to *show* for a stored message body.
  ///
  /// Every surface that displays a message body goes through this: the bubble,
  /// the inbox preview, «ستاره‌دار», search results, the notification. The
  /// database keeps the body exactly as it went over the air (it has to — that
  /// is what the device SMS provider holds and what the mirror-sync diffs
  /// against), so reconstruction happens at render time, never on the row.
  static String displayText(String body) => decode(body)?.text ?? body;

  // ── Escaping ──────────────────────────────────────────────────────────────
  //
  // `|` separates segments and a newline would break the single-line payload,
  // so both are escaped; `\` is escaped first so the two cannot be confused.

  static String _escape(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll('|', r'\|')
      .replaceAll('\r\n', r'\n')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\n');

  /// Splits on unescaped `|`, unescaping each segment as it goes.
  static List<String> _split(String payload) {
    if (payload.isEmpty) return const [];
    final segments = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < payload.length; i++) {
      final ch = payload[i];
      if (ch == '\\' && i + 1 < payload.length) {
        final next = payload[i + 1];
        buffer.write(switch (next) {
          'n' => '\n',
          '|' => '|',
          '\\' => '\\',
          // Not an escape this version defines: keep both characters rather
          // than swallowing the backslash.
          _ => '\\$next',
        });
        i++;
        continue;
      }
      if (ch == '|') {
        segments.add(buffer.toString());
        buffer.clear();
        continue;
      }
      buffer.write(ch);
    }
    segments.add(buffer.toString());
    return segments;
  }
}

/// What the fill screen (and the template picker) hands back.
///
/// Two texts, deliberately: [text] is what the user sees and edits in the
/// composer, [wire] is the compact payload that goes over the air *if the
/// composer text is still exactly [text] when send is pressed*. The user must
/// never be shown the payload — it reads as gibberish — and the payload must
/// never be sent for text it does not reconstruct.
///
/// [wire] is null whenever the compact format does not apply: a user-authored
/// template, an edited built-in, a template with no placeholders, or one where
/// the payload would not actually be shorter (see [TemplateWire.encode]).
class TemplateFillResult {
  /// The human-readable message.
  final String text;

  /// The compact payload for [text], or null when the text itself is what ships.
  final String? wire;

  const TemplateFillResult({required this.text, this.wire});
}

/// A decoded [TemplateWire] payload: which built-in template was sent and what
/// was filled into it.
class TemplateWireMessage {
  final BuiltInTemplate template;

  /// Placeholder name → answer. Placeholders the sender left blank are absent,
  /// exactly as if the sender had rendered the text themselves.
  final Map<String, String> values;

  /// The name the sender addressed the message to («<نام> عزیز»), when the
  /// «درج نام مخاطب» switch was on. Not re-derived locally: it names the
  /// recipient, and the recipient's own address book has no entry for itself.
  final String? greetingName;

  const TemplateWireMessage({
    required this.template,
    required this.values,
    this.greetingName,
  });

  /// The message as the sender composed it.
  String get text => TemplateEngine.render(
    template.body,
    values: values,
    contactName: greetingName,
    useContactName: greetingName != null,
  );
}
