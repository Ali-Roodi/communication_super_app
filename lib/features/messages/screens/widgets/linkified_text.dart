import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:url_launcher/url_launcher.dart';

import 'package:communication_super_app/core/utils/script_direction.dart';
import 'package:communication_super_app/core/utils/ussd_code.dart';
import 'phone_action_sheet.dart';
import 'ussd_action_sheet.dart';

/// Message body text with tappable links.
///
/// Detects web URLs (`http://`, `https://`, `www.`), USSD/MMI codes
/// (`*140*11#`) and phone-like numbers (8+ digits) and renders them
/// underlined; tapping opens the browser, the USSD sheet or the phone sheet.
/// When [enableTaps] is false (multi-select mode) links render styled but inert
/// so bubble taps keep toggling selection.
///
/// Each paragraph reads in its own script's direction ([ScriptDirection]): an
/// English message is left-aligned, and so is an English line inside a Persian
/// one. A body in one direction is a single [Text]; a mixed one is a column of
/// them, sized to the widest, whose selection copies back with the newlines
/// between them ([_ParagraphsSelection]).
class LinkifiedText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Color? linkColor;
  final bool enableTaps;

  const LinkifiedText({
    super.key,
    required this.text,
    this.style,
    this.linkColor,
    this.enableTaps = true,
  });

  /// Top-level domains a bare host is trusted with **on its own**, with no
  /// path after it. Anything outside this list still linkifies when it carries
  /// a path (`foo.bar/baz`) — which is the shape every short link has.
  ///
  /// Deliberately short: every entry is also a way to mis-linkify a filename
  /// or an abbreviation, so it lists the TLDs an Iranian inbox actually
  /// carries plus the ones the common shorteners live on.
  static const String _bareTlds =
      'ir|com|net|org|co|me|io|ly|gl|gd|gy|cc|to|it|app|dev|info|biz|tv|xyz|'
      'site|online|shop|store|gov|edu|ac|link|live|news|blog|space|top|fun|'
      'life|world|today|cloud|tech|digital|media|team|group|agency|company|'
      'network|pro|club|us|uk|in';

  /// A link written with no scheme and no `www.` — «b2n.ir/xK9», «bit.ly/3aZ»,
  /// «digikala.com».
  ///
  /// Every URL shortener produces exactly this shape and none of them used to
  /// be tappable: the pattern knew only `http(s)://` and `www.`, so the single
  /// most common link in an Iranian SMS rendered as inert text.
  ///
  /// Two shapes, and the split is what keeps it off ordinary prose:
  ///
  /// * a host on a [_bareTlds] domain, path optional — «digikala.com»;
  /// * a host on *any* alphabetic TLD **followed by a path** — «foo.bar/baz».
  ///
  /// The lookbehind keeps it out of email addresses and out of the middle of a
  /// longer token, and every label must be ASCII — so «۱٬۵۰۰٬۰۰۰»,
  /// «مبلغ.نهایی» and «report.pdf» are all left alone.
  static final String _bareDomain =
      r'(?<![\w@.\-/])(?:[A-Za-z0-9][A-Za-z0-9\-]*\.)+'
      '(?:(?:$_bareTlds)'
      r'(?![A-Za-z0-9])(?:/[^\s]*)?|[A-Za-z]{2,10}/[^\s]+)';

  /// Matches a bare-domain link and nothing else — how a tapped run is told
  /// apart from a phone number.
  static final RegExp _bareDomainExact = RegExp('^(?:$_bareDomain)\$');

  /// Full URLs first, so `www.` inside one is not re-matched and so the
  /// bare-domain rule below can never split one in half. Then the scheme-less
  /// links, then USSD codes (before numbers, so `**21*0912…#` is one code and
  /// not a code with a phone number inside it), then bare runs long enough to
  /// be phone numbers (which keeps OTP codes out of it).
  /// The forward USSD form is listed BEFORE the mirrored one: a run that reads
  /// as a code as written is that code, and only a run that cannot be read
  /// forwards at all is re-read backwards (see [UssdCode.correctedOf]).
  static final RegExp _linkPattern = RegExp(
    '(https?://[^\\s]+|www\\.[^\\s]+|'
    '$_bareDomain'
    '|'
    '${UssdCode.pattern.pattern}'
    '|'
    '${UssdCode.mirroredPattern.pattern}'
    r'|\+?\d[\d\- ]{7,}\d)',
  );

  /// Whether [link] is a web address this app should open in a browser —
  /// including the scheme-less short links [_bareDomain] matches.
  static bool isWebLink(String link) =>
      link.startsWith('http') ||
      link.startsWith('www.') ||
      _bareDomainExact.hasMatch(link);

  /// [link] as an absolute URL, adding the scheme a bare domain omits.
  static Uri webUriOf(String link) =>
      Uri.parse(link.startsWith('http') ? link : 'https://$link');

  static final RegExp _webUrlPattern = RegExp(r'(https?://[^\s]+|www\.[^\s]+)');

  /// First *web* URL in [text] (trailing punctuation stripped), or null —
  /// used to decide whether a bubble gets a link-preview card.
  static String? firstUrl(String text) {
    final m = _webUrlPattern.firstMatch(text);
    if (m == null) return null;
    return m.group(0)!.replaceFirst(RegExp(r'[.,;:!?)\]»]+$'), '');
  }

  /// The linkified span tree for [text]. Shared with the long-press overlay,
  /// which renders the same body as selectable text — the styling has to match
  /// the bubble exactly or the zoomed copy would visibly differ.
  ///
  /// [recognizerFor] is what makes a link tappable; passing null (the overlay,
  /// and multi-select mode) leaves the links styled but inert.
  static TextSpan buildSpan(
    String text, {
    required TextStyle base,
    Color? linkColor,
    GestureRecognizer? Function(String link)? recognizerFor,
  }) {
    final linkStyle = base.copyWith(
      color: linkColor ?? base.color,
      decoration: TextDecoration.underline,
      decorationColor: linkColor ?? base.color,
      fontWeight: FontWeight.w600,
    );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in _linkPattern.allMatches(text)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      final link = m.group(0)!;
      spans.add(
        TextSpan(
          // Drawn inside an LTR isolate. Every one of these is left-to-right
          // content sitting in an RTL paragraph, and the bidi algorithm
          // otherwise resolves their neutral characters (`*` `#` `/` `?` `+`
          // `-`) to the paragraph's direction and reorders the run around them
          // — `*140*11#` came out as `#11*140*`, and a trailing `/` on a URL
          // jumped to the front. The isolate characters are zero-width and are
          // never stored: nothing but this render path ever sees them.
          //
          // A USSD code the sender wrote backwards (see
          // [UssdCode.correctedOf]) is drawn the right way round — which is the
          // same thing the reader was already seeing, since the bidi algorithm
          // was flipping it back, but now it is also what gets copied and
          // dialled.
          text: UssdCode.isolate(UssdCode.correctedOf(link) ?? link),
          style: linkStyle,
          recognizer: recognizerFor?.call(link),
        ),
      );
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: base, children: spans);
  }

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  /// Only built for a body that mixes directions, and kept across rebuilds —
  /// the selection it holds lives in it.
  _ParagraphsSelection? _selection;

  @override
  void dispose() {
    _disposeRecognizers();
    _selection?.dispose();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _open(String raw) async {
    // A USSD/MMI code: dial it (or copy it) rather than treating the digits
    // inside as a phone number. Checked before the punctuation trim, whose
    // trailing-`#`-safe character class deliberately leaves the code intact.
    // `correctedOf` also puts a code the sender wrote backwards into dialling
    // order, so the sheet offers what the keypad can actually take.
    if (UssdCode.correctedOf(raw) case final code?) {
      if (mounted) await showUssdActionSheet(context, code);
      return;
    }
    // Trim trailing punctuation that regularly trails URLs in prose.
    final link = raw.replaceFirst(RegExp(r'[.,;:!?)\]»]+$'), '');
    final Uri uri;
    if (LinkifiedText.isWebLink(link)) {
      // Covers scheme-less short links too («b2n.ir/xK9»), which get the
      // `https://` the sender left off.
      uri = LinkifiedText.webUriOf(link);
    } else {
      // A phone number opens the in-app sheet (call / SMS / contact), never a
      // `tel:` intent: this app IS the default dialer, so the intent resolves
      // back to itself, which hangs the UI for seconds and can kill it.
      if (mounted) {
        await showPhoneActionSheet(
          context,
          link.replaceAll(RegExp(r'[\- ]'), ''),
        );
      }
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('باز کردن لینک ممکن نیست')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    Widget paragraph(({String text, TextDirection direction}) run) => Text.rich(
      LinkifiedText.buildSpan(
        run.text,
        base: base,
        linkColor: widget.linkColor,
        recognizerFor: widget.enableTaps
            ? (link) {
                final r = TapGestureRecognizer()..onTap = () => _open(link);
                _recognizers.add(r);
                return r;
              }
            : null,
      ),
      textDirection: run.direction,
      textAlign: TextAlign.start,
    );

    final runs = ScriptDirection.paragraphs(widget.text);
    if (runs.length == 1) return paragraph(runs.single);
    // Stretched to the widest run, so each one sits on its own side of the
    // bubble while the bubble still shrinks to its text.
    return SelectionContainer(
      delegate: _selection ??= _ParagraphsSelection(),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final run in runs) paragraph(run)],
        ),
      ),
    );
  }
}

/// The selection over a mixed-direction body's paragraphs.
///
/// The framework's own delegate concatenates its children's text with nothing
/// between them, so a selection across two paragraphs copied as one glued
/// line. The newline [ScriptDirection.paragraphs] took out is put back here.
class _ParagraphsSelection extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final parts = <String>[
      for (final selectable in selectables)
        if (selectable.getSelectedContent() case final SelectedContent part)
          part.plainText,
    ];
    if (parts.isEmpty) return null;
    return SelectedContent(plainText: parts.join('\n'));
  }
}
