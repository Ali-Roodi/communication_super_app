import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/core/utils/sms_address.dart';

void main() {
  group('SmsAddress.canReceive', () {
    test('an alphanumeric sender ID cannot be answered', () {
      // Every one of these is a real sender from the test device's inbox.
      for (final address in const [
        'Snapp',
        'MissedCalls',
        'DIGIPAY',
        'SoratHesab',
        'BaIrancell',
        '.IRANCELL.',
        'Kongeremeli',
      ]) {
        expect(
          SmsAddress.canReceive(address),
          isFalse,
          reason: '$address is an alphanumeric originating address',
        );
      }
    });

    test('an ordinary number can, in every spelling', () {
      for (final address in const [
        '09123091194',
        '+989123091194',
        '00989123091194',
        '9123091194',
        '021 8814 1859',
        '021-8814-1859',
        '۰۹۱۲۳۰۹۱۱۹۴',
      ]) {
        expect(SmsAddress.canReceive(address), isTrue, reason: address);
      }
    });

    test('a numeric service number stays answerable', () {
      // Iranian carriers ask for replies to these constantly («برای لغو عدد ۱۱
      // را به همین شماره ارسال کنید»), so they are deliberately NOT blocked.
      for (final address in const [
        '5000301630',
        '+985000308777',
        '+9890009659',
        '50003053924',
        '100010',
      ]) {
        expect(SmsAddress.canReceive(address), isTrue, reason: address);
      }
    });

    test('an empty or digit-less address cannot be answered', () {
      expect(SmsAddress.canReceive(''), isFalse);
      expect(SmsAddress.canReceive('   '), isFalse);
      expect(SmsAddress.canReceive('+'), isFalse);
      expect(SmsAddress.canReceive('--()'), isFalse);
      // Two digits is below the floor; three is the shortest destination.
      expect(SmsAddress.canReceive('12'), isFalse);
      expect(SmsAddress.canReceive('123'), isTrue);
    });

    test('a number with a letter in it is not a destination', () {
      // A contact somebody saved as «0912 داخلی 3» — the send would fail every
      // time, so it may not be picked as a group member or a forward target.
      expect(SmsAddress.canReceive('0912 داخلی 3'), isFalse);
      expect(SmsAddress.canReceive('0912x3'), isFalse);
    });
  });
}
