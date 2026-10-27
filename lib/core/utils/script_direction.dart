import 'package:flutter/painting.dart' show TextDirection;

/// Which way a piece of text reads, decided from the letters it is written in.
///
/// A message is laid out paragraph by paragraph, the way Android's own
/// `TextView` does it (each paragraph gets its own direction): an all-Latin
/// message reads left to right and is aligned to the left, and a Latin line
/// inside a Persian message is aligned to the left on its own while the
/// Persian lines around it stay on the right.
///
/// A paragraph's direction is its **majority script**, counted in letters, not
/// its first letter. «Hamresan یک پیام‌رسان امن است» is a Persian sentence
/// that happens to open with a Latin name; first-strong would have turned the
/// whole line around. A tie reads right to left, the app's own direction.
abstract final class ScriptDirection {
  /// The direction [text]'s letters ask for, or null when it has none — a
  /// line of digits, punctuation, emoji or nothing at all, which follows the
  /// lines around it.
  static TextDirection? of(String text) {
    var rtl = 0;
    var ltr = 0;
    for (final c in text.runes) {
      if (_isRtlLetter(c)) {
        rtl++;
      } else if (_isLtrLetter(c)) {
        ltr++;
      }
    }
    if (rtl == 0 && ltr == 0) return null;
    return ltr > rtl ? TextDirection.ltr : TextDirection.rtl;
  }

  /// [text] cut into runs of whole lines that read the same way, in order.
  ///
  /// The `\n` between two runs is **not** part of either — whoever draws them
  /// puts each run on its own line, and whoever copies them joins them with
  /// it again. A blank or letterless line goes with the run before it (the
  /// first run, when it leads), so it keeps its place and no run starts with a
  /// newline. All of [text] in one direction is one run, the text itself.
  static List<({String text, TextDirection direction})> paragraphs(
    String text, {
    TextDirection fallback = TextDirection.rtl,
  }) {
    final lines = text.split('\n');
    final own = [for (final line in lines) of(line)];
    final first = own.firstWhere((d) => d != null, orElse: () => null);
    final runs = <({String text, TextDirection direction})>[];
    final buffer = StringBuffer();
    TextDirection? current;
    for (var i = 0; i < lines.length; i++) {
      final direction = own[i] ?? current ?? first ?? fallback;
      if (current != null && direction != current) {
        runs.add((text: buffer.toString(), direction: current));
        buffer.clear();
      } else if (current != null) {
        buffer.write('\n');
      }
      buffer.write(lines[i]);
      current = direction;
    }
    runs.add((text: buffer.toString(), direction: current ?? fallback));
    return runs;
  }

  /// Hebrew, Arabic and the scripts between them, and their presentation
  /// forms — letters only. The Arabic block also holds digits (۰–۹, ٠–٩),
  /// harakat and punctuation, which carry no direction and are not counted.
  static bool _isRtlLetter(int c) {
    if (c < 0x0590) return false;
    if (c <= 0x08FF) {
      if (c >= 0x0660 && c <= 0x0669) return false; // Arabic-Indic digits
      if (c >= 0x06F0 && c <= 0x06F9) return false; // Persian digits
      if (c >= 0x064B && c <= 0x065F) return false; // harakat
      if (c == 0x0670) return false; // superscript alef
      if (c >= 0x06D6 && c <= 0x06ED) return false; // Quranic marks
      if (c >= 0x0600 && c <= 0x061F) return false; // signs, ، ؛ ؟
      if (c >= 0x066A && c <= 0x066D) return false; // ٪ ٫ ٬ ٭
      if (c == 0x06D4) return false; // ۔
      return true;
    }
    return (c >= 0xFB1D && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFC);
  }

  /// Latin (with its accented forms), Greek and Cyrillic letters.
  static bool _isLtrLetter(int c) {
    if (c < 0x41) return false;
    if (c <= 0x5A) return true;
    if (c >= 0x61 && c <= 0x7A) return true;
    if (c >= 0xC0 && c <= 0x24F) return c != 0xD7 && c != 0xF7; // × ÷
    if (c >= 0x370 && c <= 0x3FF) return c != 0x37E && c != 0x387;
    if (c >= 0x400 && c <= 0x4FF) return true;
    if (c >= 0x1E00 && c <= 0x1EFF) return true; // Latin Extended Additional
    return false;
  }
}
