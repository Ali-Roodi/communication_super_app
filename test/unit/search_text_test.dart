import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';

ContactModel _contact(
  String id,
  String name,
  List<String> phones, {
  String? email,
}) {
  final now = DateTime(2026);
  return ContactModel(
    id: id,
    name: name,
    phoneNumber: phones.isEmpty ? '' : phones.first,
    phoneNumbers: phones,
    email: email,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('SearchText.phoneContains', () {
    test('+98, 0098, 98, 0 and the bare national number are one number', () {
      const stored = '+98 912 123 4567';
      for (final typed in [
        '09121234567',
        '9121234567',
        '989121234567',
        '00989121234567',
        '+989121234567',
        '0912 123 4567',
      ]) {
        expect(
          SearchText.phoneContains(stored, typed),
          isTrue,
          reason: 'typing $typed must find $stored',
        );
      }
    });

    test('the reverse direction works too (stored 0…, typed +98…)', () {
      expect(SearchText.phoneContains('09121234567', '+989121234567'), isTrue);
      expect(SearchText.phoneContains('0912-123-4567', '98912'), isTrue);
    });

    test('a partial run in the middle still matches', () {
      expect(SearchText.phoneContains('+989121234567', '1234'), isTrue);
      expect(SearchText.phoneContains('+989121234567', '4321'), isFalse);
    });

    test('Persian and Arabic digits are the same digits', () {
      expect(SearchText.phoneContains('09121234567', '۰۹۱۲'), isTrue);
      expect(SearchText.phoneContains('09121234567', '٠٩١٢'), isTrue);
    });

    test('an empty query matches nothing', () {
      expect(SearchText.phoneContains('09121234567', ''), isFalse);
      expect(SearchText.phoneContains('09121234567', 'abc'), isFalse);
    });
  });

  group('SearchText.nameContains', () {
    test('Arabic and Persian letter variants fold together', () {
      expect(SearchText.nameContains('علی رضایی', 'علي'), isTrue);
      expect(SearchText.nameContains('كامران', 'کامران'), isTrue);
      expect(SearchText.nameContains('آرش', 'ارش'), isTrue);
      expect(SearchText.nameContains('فاطمة', 'فاطمه'), isTrue);
    });

    test('a ZWNJ inside the stored name is ignored', () {
      expect(SearchText.nameContains('محمد‌رضا', 'محمدرضا'), isTrue);
      expect(SearchText.nameContains('محمد‌رضا', 'رضا'), isTrue);
    });

    test('spacing differences do not hide a match', () {
      expect(SearchText.nameContains('محمد رضا', 'محمدرضا'), isTrue);
    });

    test('latin names are case-insensitive', () {
      expect(SearchText.nameContains('John Smith', 'john'), isTrue);
      expect(SearchText.nameContains('John Smith', 'SMITH'), isTrue);
      expect(SearchText.nameContains('John Smith', 'jane'), isFalse);
    });
  });

  group('SearchText.matchRange', () {
    test('returns indices into the original string, not the folded one', () {
      const name = 'محمد‌رضا';
      final range = SearchText.matchRange(name, 'رضا');
      expect(range, isNotNull);
      final (start, end) = range!;
      expect(name.substring(start, end), 'رضا');
    });

    test('null when the name does not contain the query', () {
      expect(SearchText.matchRange('علی', 'حسن'), isNull);
    });
  });

  group('ContactRepository.matchContacts', () {
    final contacts = [
      _contact('1', 'علی رضایی', ['+98 912 123 4567']),
      _contact('2', 'كامران', ['09350000000', '02112345678']),
      _contact('3', 'John Smith', ['+15551234567'], email: 'john@example.com'),
      _contact('4', 'بدون شماره', const []),
    ];

    test('a number typed as 0… finds a contact stored as +98…', () {
      expect(
        ContactRepository.matchContacts(
          contacts,
          '09121234567',
        ).map((c) => c.id),
        ['1'],
      );
      expect(
        ContactRepository.matchContacts(contacts, '0912').map((c) => c.id),
        ['1'],
      );
    });

    test('a second number of a contact is searchable', () {
      expect(
        ContactRepository.matchContacts(contacts, '021').map((c) => c.id),
        ['2'],
      );
    });

    test('a name typed with the other keyboard still matches', () {
      expect(
        ContactRepository.matchContacts(contacts, 'کامران').map((c) => c.id),
        ['2'],
      );
    });

    test('email is searchable', () {
      expect(
        ContactRepository.matchContacts(
          contacts,
          'example.com',
        ).map((c) => c.id),
        ['3'],
      );
    });

    test('an empty query returns everything', () {
      expect(ContactRepository.matchContacts(contacts, '   ').length, 4);
    });

    test('a purely numeric query never falls back to a name match', () {
      // «بدون شماره» has no number, so digits must not reach the name matcher.
      expect(ContactRepository.matchContacts(contacts, '99999'), isEmpty);
    });
  });

  group('ContactRepository.matchPhoneDigits', () {
    final repo = ContactRepository();
    final ali = _contact('1', 'علی', ['+98 912 123 4567', '0935 000 0000']);

    test('matches a +98 number by its national form', () {
      final matches = repo.matchPhoneDigits([ali], '09121234567');
      expect(matches, hasLength(1));
      expect(matches.single.number, '+98 912 123 4567');
    });

    test('yields one match per matching number of the contact', () {
      expect(repo.matchPhoneDigits([ali], '09').map((m) => m.number), [
        '+98 912 123 4567',
        '0935 000 0000',
      ]);
    });

    test('the reported range points at the digits that matched', () {
      final match = repo.matchPhoneDigits([ali], '1234').single;
      expect(
        match.digits.substring(
          match.matchStart,
          match.matchStart + match.matchLength,
        ),
        '1234',
      );
    });
  });

  group('SearchText.t9MatchRange', () {
    ({int start, int end})? range(String name, String digits) {
      final r = SearchText.t9MatchRange(name, digits);
      return r == null ? null : (start: r.$1, end: r.$2);
    }

    test('finds a Persian name by its keypad digits', () {
      // ک=۷ ب=۲ ر=۴
      expect(range('کبری رضایی', '724'), (start: 0, end: 3));
    });

    test('matches a later word from its own start', () {
      // ر=۴ ض=۵ ا=۲ — the surname, typed on its own.
      expect(range('کبری رضایی', '452'), (start: 5, end: 8));
    });

    test('never matches inside a word', () {
      // «ب ر ی» is a real run of «کبری», but nobody types a name from its
      // second letter — allowing it answers three digits with the address book.
      expect(range('کبری رضایی', '249'), isNull);
    });

    test('folds the Arabic spellings onto the same keys', () {
      // «ي» and «ك» come from an Arabic keyboard and must land on ی / ک.
      expect(range('كبري', '724'), isNotNull);
    });

    test('the range indexes the ORIGINAL name, ZWNJ and all', () {
      // م=۸ ح=۳ م=۸ د=۴ — the ZWNJ inside «محمد‌رضا» is dropped when folding,
      // so an index taken on the folded copy would land a letter early.
      const name = 'محمد‌رضا';
      final r = range(name, '8384')!;
      expect(name.substring(r.start, r.end), 'محمد');
    });

    test('reads latin names off the same keys', () {
      expect(range('Sara', '7272'), (start: 0, end: 4));
    });

    test('one digit is not a query', () {
      expect(range('کبری', '7'), isNull);
    });
  });

  group('matchPhoneDigits — T9', () {
    final repo = ContactRepository();
    final kobra = _contact('1', 'کبری رضایی', ['0912 000 1111']);
    final ali = _contact('2', 'علی', ['0935 000 0000']);

    test('a name typed on the keys is a suggestion', () {
      final matches = repo.matchPhoneDigits([kobra, ali], '724');
      expect(matches.single.contact.id, '1');
      expect(matches.single.number, '0912 000 1111');
      expect(matches.single.isT9, isTrue);
    });

    test('number hits come first and are never repeated as T9 hits', () {
      // ۰۹۱۲ matches کبری's number; «۰۹» is not a T9 run of any name here.
      final matches = repo.matchPhoneDigits([kobra, ali], '0912');
      expect(matches, hasLength(1));
      expect(matches.single.isT9, isFalse);
    });

    test('the highlighted range points at the letters that were typed', () {
      final match = repo.matchPhoneDigits([kobra], '724').single;
      expect(
        match.contact.name.substring(
          match.nameStart,
          match.nameStart + match.nameLength,
        ),
        'کبر',
      );
    });
  });
}
