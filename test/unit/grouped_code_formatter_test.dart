import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/core/utils/grouped_code_formatter.dart';

void main() {
  const code = GroupedCodeFormatter(maxLength: 16);

  TextEditingValue at(String text, int caret) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret),
  );

  /// Types [typed] one character at a time at the end, as a keyboard does.
  TextEditingValue type(GroupedCodeFormatter f, String typed) {
    var value = TextEditingValue.empty;
    for (final c in typed.split('')) {
      final next = value.text + c;
      value = f.formatEditUpdate(value, at(next, next.length));
    }
    return value;
  }

  test('a dash follows every complete group of four', () {
    expect(type(code, 'abc').text, 'ABC');
    expect(type(code, 'abcd').text, 'ABCD-');
    expect(type(code, 'abcde').text, 'ABCD-E');
    final full = type(code, 'abcd2345wxyz6789');
    expect(full.text, 'ABCD-2345-WXYZ-6789');
    expect(full.selection.baseOffset, full.text.length);
  });

  test('nothing past the last character, and no trailing dash there', () {
    expect(type(code, 'abcd2345wxyz6789zz').text, 'ABCD-2345-WXYZ-6789');
  });

  test('a typed or pasted dash, space or other letter is not a character', () {
    expect(type(code, 'ab-cd ef').text, 'ABCD-EF');
    expect(
      code.formatEditUpdate(TextEditingValue.empty, at('ab cd-ef/gh', 11)).text,
      'ABCD-EFGH-',
    );
    // Persian and Arabic digits are digits.
    expect(type(code, '۲۳۴۵٦٧').text, '2345-67');
    // A Persian letter is not part of any code.
    expect(type(code, 'abسcd').text, 'ABCD-');
  });

  test('backspace right after a dash takes the character before it', () {
    // «ABCD-» with the caret at its end; the keyboard deletes the dash.
    final after = code.formatEditUpdate(at('ABCD-', 5), at('ABCD', 4));
    expect(after.text, 'ABC');
    expect(after.selection.baseOffset, 3);
    // The same in the middle of a code.
    final middle = code.formatEditUpdate(at('ABCD-EFGH', 5), at('ABCDEFGH', 4));
    expect(middle.text, 'ABCE-FGH');
    expect(middle.selection.baseOffset, 3);
  });

  test('ordinary backspace removes one character', () {
    final v = code.formatEditUpdate(at('ABCD-EF', 7), at('ABCD-E', 6));
    expect(v.text, 'ABCD-E');
    expect(v.selection.baseOffset, 6);
  });

  test('typing in the middle keeps the caret after what was typed', () {
    // Caret after «E» in «ABCD-EFGH»; X typed there.
    final v = code.formatEditUpdate(at('ABCD-EFGH', 6), at('ABCD-EXFGH', 7));
    expect(v.text, 'ABCD-EXFG-H');
    expect(v.selection.baseOffset, 7);
  });

  test('clearing a selection clears the field', () {
    final v = code.formatEditUpdate(
      const TextEditingValue(
        text: 'ABCD-EF',
        selection: TextSelection(baseOffset: 0, extentOffset: 7),
      ),
      at('', 0),
    );
    expect(v.text, '');
  });

  test('a password is twenty characters in five groups', () {
    const password = GroupedCodeFormatter(maxLength: 20);
    expect(
      type(password, 'pqrs2345wxyzabcd6789').text,
      'PQRS-2345-WXYZ-ABCD-6789',
    );
  });
}
