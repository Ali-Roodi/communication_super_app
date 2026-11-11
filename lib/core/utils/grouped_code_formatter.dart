import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Types a key-bank code or key-file password in groups of four —
/// `ABCD-EFGH-…`, as the issuance panel prints them — with the dashes put in
/// by the field, never by the user.
///
/// Only letters and digits mean anything to the app (`Canon.keyFilePassword`,
/// `MemberCode.read`): case, dashes and spaces are ignored there. So the field
/// keeps exactly that — Latin letters upper-cased, Persian and Arabic digits
/// turned into Latin ones — drops everything else, and lays the result out
/// again on every edit. A dash appears as soon as a group of four is complete,
/// so the user sees where the next group starts.
///
/// Two edits need care, and both are handled here:
///
/// * **Backspace right after a dash.** Removing the dash alone would leave the
///   same characters, the layout would put the dash straight back and the key
///   would look dead. A deleted dash takes the character before it with it.
/// * **The caret.** It is placed by counting the characters that mean
///   something before it, not by offset, so typing or deleting in the middle
///   of a code does not throw it to the end.
class GroupedCodeFormatter extends TextInputFormatter {
  const GroupedCodeFormatter({required this.maxLength});

  /// How many letters and digits the field accepts (16 for a code, 20 for a
  /// key-file password). Anything typed or pasted past it is dropped.
  final int maxLength;

  static const int group = 4;
  static const String separator = '-';

  /// Whether [unit] (a UTF-16 code unit) is a letter or digit the app reads.
  static bool _significant(int unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A) ||
      (unit >= 0x06F0 && unit <= 0x06F9) ||
      (unit >= 0x0660 && unit <= 0x0669);

  /// The letters and digits of [text], normalised: upper case, Latin digits.
  static String significant(String text) {
    final out = StringBuffer();
    for (final unit in text.codeUnits) {
      if (!_significant(unit)) continue;
      if (unit >= 0x06F0 && unit <= 0x06F9) {
        out.writeCharCode(0x30 + unit - 0x06F0);
      } else if (unit >= 0x0660 && unit <= 0x0669) {
        out.writeCharCode(0x30 + unit - 0x0660);
      } else if (unit >= 0x61 && unit <= 0x7A) {
        out.writeCharCode(unit - 0x20);
      } else {
        out.writeCharCode(unit);
      }
    }
    return out.toString();
  }

  /// [chars] (already [significant]) laid out in groups, with a trailing dash
  /// once a group is complete and more may follow.
  String layout(String chars) {
    final out = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % group == 0) out.write(separator);
      out.write(chars[i]);
    }
    if (chars.isNotEmpty &&
        chars.length % group == 0 &&
        chars.length < maxLength) {
      out.write(separator);
    }
    return out.toString();
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var raw = newValue.text;
    int caret = newValue.selection.isValid
        ? math.min(math.max(newValue.selection.extentOffset, 0), raw.length)
        : raw.length;

    // One dash deleted and nothing else: take the character before it too.
    final deletedOne =
        oldValue.text.length - raw.length == 1 &&
        newValue.selection.isCollapsed &&
        oldValue.selection.isCollapsed &&
        caret < oldValue.text.length &&
        oldValue.text[caret] == separator &&
        significant(oldValue.text) == significant(raw);
    if (deletedOne) {
      var i = caret - 1;
      while (i >= 0 && !_significant(raw.codeUnitAt(i))) {
        i--;
      }
      if (i >= 0) {
        raw = raw.replaceRange(i, i + 1, '');
        caret = i;
      }
    }

    var chars = significant(raw);
    if (chars.length > maxLength) chars = chars.substring(0, maxLength);
    final int before = math.min(
      significant(raw.substring(0, caret)).length,
      chars.length,
    );
    final text = layout(chars);
    final dashes = separator.allMatches(text).length;
    final int offset = before + math.min(before ~/ group, dashes);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
