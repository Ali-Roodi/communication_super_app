import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/models/one_time_code.dart';

void main() {
  group('OneTimeCode.find', () {
    test('reads the code out of a bank one-time-password SMS', () {
      expect(
        OneTimeCode.find('رمز پویا: 84213 - بانک ملت'),
        '84213',
      );
    });

    test('answers in ASCII even when the message used Persian digits', () {
      // The code is pasted into another app's field, where «۸۴۲۱۳» is useless.
      expect(OneTimeCode.find('کد تایید شما ۸۴۲۱۳ است'), '84213');
    });

    test('a message with no code word carries no code', () {
      expect(OneTimeCode.find('فردا ساعت 1030 قرار داریم'), isNull);
    });

    test('an amount is not a code', () {
      expect(
        OneTimeCode.find('رمز پویا: 84213 مبلغ 1,500,000 ریال'),
        '84213',
      );
    });

    test('a date is not a code', () {
      expect(OneTimeCode.find('کد ورود 1405/05/20 صادر شد'), isNull);
    });

    test('a code ending the sentence keeps its full stop out of the way', () {
      expect(OneTimeCode.find('کد: 12345.'), '12345');
    });

    test('a long number is an account, not a code', () {
      expect(OneTimeCode.find('کد پیگیری 1234567890123'), isNull);
    });

    test('picks the run nearest the word that announced it', () {
      expect(
        OneTimeCode.find('مبلغ 25000 ریال. رمز 84213'),
        '84213',
      );
    });

    test('a discount amount next to «کد» is not the code', () {
      // Seen on a real SnappFood message: the code itself is alphanumeric
      // (deliberately out of scope), and the only digit run is the price.
      // Copying the price under a «کپی» chip is worse than offering nothing.
      expect(
        OneTimeCode.find(
          'کد تخفیف 300000 تومانی زیر به عنوان هدیه به شما تقدیم می شود. D7BXWP445M6J',
        ),
        isNull,
      );
    });

    test('a round number is a quantity, not a code', () {
      expect(OneTimeCode.find('کد شارژ 50000 اعمال شد'), isNull);
    });

    test('the real login code still wins next to an amount', () {
      expect(
        OneTimeCode.find('کد ورود 44808 - اعتبار 20000 تومان'),
        '44808',
      );
    });

    test('English senders work too', () {
      expect(OneTimeCode.find('Your verification code is 550123'), '550123');
    });
  });
}
