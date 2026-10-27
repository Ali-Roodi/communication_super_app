import 'package:communication_super_app/core/utils/script_direction.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rtl = TextDirection.rtl;
  const ltr = TextDirection.ltr;

  group('of', () {
    test('a Latin message reads left to right', () {
      expect(ScriptDirection.of('Your code is 1234'), ltr);
      expect(ScriptDirection.of('Привет'), ltr);
    });

    test('a Persian message reads right to left', () {
      expect(ScriptDirection.of('سلام، خوبی؟'), rtl);
    });

    test('the majority script decides, not the first letter', () {
      expect(ScriptDirection.of('Hamresan یک پیام‌رسان امن است'), rtl);
      expect(ScriptDirection.of('سلام, how are you doing today'), ltr);
    });

    test('a tie reads right to left', () {
      expect(ScriptDirection.of('ab پی'), rtl);
    });

    test('digits, punctuation and emoji carry no direction', () {
      expect(ScriptDirection.of('۱۲۳۴۵ 678 ٪ ؟ *140# 😀'), isNull);
      expect(ScriptDirection.of(''), isNull);
    });

    test('Persian digits do not outvote a Latin word', () {
      expect(ScriptDirection.of('OK ۱۲۳۴۵۶۷۸'), ltr);
    });
  });

  group('paragraphs', () {
    test('one direction is the text itself, as one run', () {
      expect(ScriptDirection.paragraphs('سلام\nخوبی'), [
        (text: 'سلام\nخوبی', direction: rtl),
      ]);
      expect(ScriptDirection.paragraphs('Hi\nthere'), [
        (text: 'Hi\nthere', direction: ltr),
      ]);
    });

    test('a Latin line inside a Persian message is its own run', () {
      expect(ScriptDirection.paragraphs('رمز ورود:\nHello World\nممنون'), [
        (text: 'رمز ورود:', direction: rtl),
        (text: 'Hello World', direction: ltr),
        (text: 'ممنون', direction: rtl),
      ]);
    });

    test('blank and letterless lines stay with the run before them', () {
      expect(ScriptDirection.paragraphs('سلام\n\n12345\nHello'), [
        (text: 'سلام\n\n12345', direction: rtl),
        (text: 'Hello', direction: ltr),
      ]);
    });

    test('leading letterless lines take the first direction', () {
      expect(ScriptDirection.paragraphs('1234\nHello\nسلام'), [
        (text: '1234\nHello', direction: ltr),
        (text: 'سلام', direction: rtl),
      ]);
    });

    test('a body with no letters falls back to the app direction', () {
      expect(ScriptDirection.paragraphs('12345'), [
        (text: '12345', direction: rtl),
      ]);
    });

    test('joining the runs with a newline gives the text back', () {
      for (final text in [
        'a\nب\n\nc\n',
        '\n\nHello\nسلام\n',
        'x',
        '',
        'سلام\nHi\n\n\nخداحافظ',
      ]) {
        final runs = ScriptDirection.paragraphs(text);
        expect(runs.map((r) => r.text).join('\n'), text, reason: text);
      }
    });
  });
}
