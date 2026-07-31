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
        ContactRepository.matchContacts(contacts, '09121234567').map((c) => c.id),
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
        ContactRepository.matchContacts(contacts, 'example.com').map((c) => c.id),
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
}
