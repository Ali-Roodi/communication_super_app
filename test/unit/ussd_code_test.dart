import 'package:flutter_test/flutter_test.dart';
import 'package:communication_super_app/core/utils/ussd_code.dart';

void main() {
  String? first(String s) => UssdCode.pattern.firstMatch(s)?.group(0);

  group('UssdCode.pattern', () {
    test('matches the codes Iranian carriers actually send', () {
      expect(first('برای شارژ *140*11# را شماره‌گیری کنید'), '*140*11#');
      expect(first('اعتبار خود را با *140# ببینید'), '*140#');
      expect(first('کد: *#06#'), '*#06#');
      expect(first('انتقال: **21*09121234567#'), '**21*09121234567#');
      expect(first('#100#'), '#100#');
      expect(first('کد *۷۸۰*۰# را بگیرید'), '*۷۸۰*۰#');
    });

    test('leaves prose and ordinary numbers alone', () {
      expect(first('سلام، حال شما چطور است؟'), isNull);
      expect(first('شماره من 09121234567 است'), isNull);
      expect(first('*مهم* لطفا بخوانید'), isNull);
      // An MMI *prefix* on a real call is not a standalone code.
      expect(first('#31#09121234567'), isNull);
      // No digits between the delimiters.
      expect(first('**#'), isNull);
    });

    test('isCode is whole-string only', () {
      expect(UssdCode.isCode('*140*11#'), isTrue);
      expect(UssdCode.isCode('کد *140*11# است'), isFalse);
    });
  });

  group('UssdCode.toDialable', () {
    test('folds Persian and Arabic-Indic digits, keeps * and #', () {
      expect(UssdCode.toDialable('*۱۴۰*۱۱#'), '*140*11#');
      expect(UssdCode.toDialable('*٧٨٠*٠#'), '*780*0#');
      expect(UssdCode.toDialable('*140*11#'), '*140*11#');
    });

    test('strips the bidi isolate a rendered code would carry', () {
      expect(UssdCode.toDialable(UssdCode.isolate('*140#')), '*140#');
    });
  });

  mirroredTests();
}

// ── Mirrored codes ─────────────────────────────────────────────────────────
//
// Verified against a live Irancell SMS: its Persian half stores
// «خرید بسته اینترنت: #5*555*» — the code typed in visual order so an RTL
// renderer would show «*555*5#». It reads right and dials wrong.
void mirroredTests() {
  group('UssdCode mirrored', () {
    test('reads a backwards code back into dialling order', () {
      expect(UssdCode.correctedOf('#5*555*'), '*555*5#');
      expect(UssdCode.dialableOf('#5*555*'), '*555*5#');
      expect(
        UssdCode.mirroredPattern.firstMatch('اینترنت: #5*555* و')?.group(0),
        '#5*555*',
      );
    });

    test('a run that reads forwards is NEVER re-read backwards', () {
      // Both directions are well-formed; the written one wins.
      expect(UssdCode.correctedOf('#001#'), '#001#');
      expect(UssdCode.correctedOf('*140*11#'), '*140*11#');
      expect(UssdCode.mirroredPattern.firstMatch('#001#'), isNull);
    });

    test('leaves runs that are codes in neither direction alone', () {
      expect(UssdCode.correctedOf('#**'), isNull);
      expect(UssdCode.correctedOf('09121234567'), isNull);
      expect(UssdCode.mirroredPattern.firstMatch('#31#09121234567'), isNull);
    });
  });
}
