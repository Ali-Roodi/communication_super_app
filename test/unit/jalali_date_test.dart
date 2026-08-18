import 'package:flutter_test/flutter_test.dart';
import 'package:communication_super_app/core/utils/jalali_date.dart';

void main() {
  group('JalaliDate.fromDateTime', () {
    test('Nowruz 1403 = 2024-03-20', () {
      final j = JalaliDate.fromDateTime(DateTime(2024, 3, 20));
      expect([j.year, j.month, j.day], [1403, 1, 1]);
    });

    test('22 Bahman 1357 = 1979-02-11', () {
      final j = JalaliDate.fromDateTime(DateTime(1979, 2, 11));
      expect([j.year, j.month, j.day], [1357, 11, 22]);
    });

    test('does not mislabel a Gregorian July as مهر', () {
      final j = JalaliDate.fromDateTime(DateTime(2026, 7, 1));
      // July falls in تیر/مرداد, never مهر (the old bug).
      expect(j.monthName, isNot('مهر'));
      expect(j.month, inInclusiveRange(4, 5));
    });
  });

  group('round-trip', () {
    test('fromDateTime → toDateTime is stable for many dates', () {
      for (
        var d = DateTime(1990, 1, 1);
        d.isBefore(DateTime(2035, 1, 1));
        d = d.add(const Duration(days: 17))
      ) {
        final j = JalaliDate.fromDateTime(d);
        final back = JalaliDate.toDateTime(j.year, j.month, j.day);
        expect(
          [back.year, back.month, back.day],
          [d.year, d.month, d.day],
          reason: 'failed for $d (jalali ${j.year}/${j.month}/${j.day})',
        );
      }
    });
  });

  group('monthLength', () {
    test('first six months have 31 days', () {
      for (var m = 1; m <= 6; m++) {
        expect(JalaliDate.monthLength(1403, m), 31);
      }
    });

    test('months 7-11 have 30 days', () {
      for (var m = 7; m <= 11; m++) {
        expect(JalaliDate.monthLength(1403, m), 30);
      }
    });

    test('Esfand is 30 in leap year 1403 and 29 in common year 1404', () {
      expect(JalaliDate.monthLength(1403, 12), 30);
      expect(JalaliDate.monthLength(1404, 12), 29);
    });
  });
}
