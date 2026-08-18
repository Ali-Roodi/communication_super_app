import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/core/utils/contact_name_style.dart';
import 'package:communication_super_app/core/utils/persian_alphabet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const letters = kPersianIndexLetters;

  List<String> sorted(List<String> names) {
    final keyed = [
      for (final n in names)
        (key: PersianCollator.sortKey(n, letters), name: n),
    ]..sort((a, b) => a.key.compareTo(b.key));
    return [for (final e in keyed) e.name];
  }

  group('PersianCollator', () {
    test('orders by the Persian alphabet, not by code unit', () {
      // پ (0x067E), چ (0x0686), ژ (0x0698), گ (0x06AF) and ک (0x06A9) all sit
      // outside the ب…ی run, so `compareTo` scatters them.
      expect(
        sorted(['گلی', 'بهرام', 'پریسا', 'یاسر', 'ژاله', 'چنگیز', 'کاوه']),
        ['بهرام', 'پریسا', 'چنگیز', 'ژاله', 'کاوه', 'گلی', 'یاسر'],
      );
    });

    test('folds the Arabic spellings onto the Persian ones', () {
      // «علي» (Arabic ي) and «علی» must land next to each other, and «آرش»
      // sorts as «ارش» — under ا, after «ابراهیم», not in a bucket of its own.
      expect(sorted(['علي', 'آرش', 'علی', 'ابراهیم']), [
        'ابراهیم',
        'آرش',
        'علي',
        'علی',
      ]);
    });

    test('names outside the active alphabet sort last, in the # bucket', () {
      expect(sorted(['Zoe', 'یاسر', 'الف', '123']), [
        'الف',
        'یاسر',
        'Zoe',
        '123',
      ]);
    });

    test('the order never disagrees with the section ranks', () {
      // The fast-scroll index jumps to an offset accumulated from the section
      // ranks in order, so a list sorted against those ranks lands the jump on
      // the wrong name.
      final ordered = sorted(['یاسر', 'Zoe', 'بهرام', 'کاوه', 'آرش']);
      final ranks = [
        for (final n in ordered)
          letterRank(sectionLetterFor(n, letters), letters),
      ];
      expect(ranks, orderedEquals([...ranks]..sort()));
    });
  });

  group('ContactNameStyle', () {
    setUp(() {
      ContactNameStyle.lastNameFirst = false;
      ContactNameStyle.sortByLastName = false;
    });

    test('off, the provider display name is used verbatim', () {
      expect(
        ContactNameStyle.format(
          displayName: 'علی رودی',
          first: 'علی',
          last: 'رودی',
        ),
        'علی رودی',
      );
    });

    test('on, the family name comes first', () {
      ContactNameStyle.lastNameFirst = true;
      expect(
        ContactNameStyle.format(
          displayName: 'علی رودی',
          first: 'علی',
          last: 'رودی',
        ),
        'رودی، علی',
      );
    });

    test('a name with only one half is left alone', () {
      ContactNameStyle.lastNameFirst = true;
      // A one-word contact, a company row, a SIM (ADN) record: nothing to swap,
      // and «، » with an empty side reads as a typo.
      expect(
        ContactNameStyle.format(displayName: 'دفتر', first: 'دفتر', last: ''),
        'دفتر',
      );
      expect(ContactNameStyle.format(displayName: 'مغازه'), 'مغازه');
    });

    test('sortSource orders by family name without changing the display', () {
      ContactNameStyle.sortByLastName = true;
      expect(
        ContactNameStyle.sortSource(
          displayName: 'علی رودی',
          first: 'علی',
          last: 'رودی',
        ),
        'رودی علی',
      );
    });

    test('apply announces a real change exactly once', () async {
      final seen = <void>[];
      final sub = ContactNameStyle.onChanged.listen(seen.add);
      ContactNameStyle.apply(lastNameFirst: true, sortByLastName: false);
      ContactNameStyle.apply(lastNameFirst: true, sortByLastName: false);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, hasLength(1));
      expect(ContactNameStyle.lastNameFirst, isTrue);
    });
  });
}
