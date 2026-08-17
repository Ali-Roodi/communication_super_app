import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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

  /// URLs first (so `www.` inside a URL isn't re-matched), then USSD codes
  /// (before numbers, so `**21*0912…#` is one code and not a code with a phone
  /// number inside it), then bare numbers long enough to be phone numbers
  /// (avoids linkifying OTP codes).
  /// The forward USSD form is listed BEFORE the mirrored one: a run that reads
  /// as a code as written is that code, and only a run that cannot be read
  /// forwards at all is re-read backwards (see [UssdCode.correctedOf]).
  static final RegExp _linkPattern = RegExp(
    '(https?://[^\\s]+|www\\.[^\\s]+|'
    '${UssdCode.pattern.pattern}'
    '|'
    '${UssdCode.mirroredPattern.pattern}'
    r'|\+?\d[\d\- ]{7,}\d)',
  );

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

  @override
  void dispose() {
    _disposeRecognizers();
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
    if (link.startsWith('http')) {
      uri = Uri.parse(link);
    } else if (link.startsWith('www.')) {
      uri = Uri.parse('https://$link');
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
    return Text.rich(
      LinkifiedText.buildSpan(
        widget.text,
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
    );
  }
}
