import 'dart:convert';
import 'dart:typed_data';

import 'package:communication_super_app/features/contacts/models/contact_save_target.dart';
import 'package:communication_super_app/features/contacts/models/vcf_file.dart';
import 'package:communication_super_app/features/contacts/services/contact_file_service.dart';
import 'package:communication_super_app/features/contacts/services/sim_contacts_service.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// As Android's contacts provider writes it: vCard 2.1, quoted-printable,
/// CRLF. The name is «علی رضایی», the note holds a literal percent sign.
const _android21 =
    'BEGIN:VCARD\r\n'
    'VERSION:2.1\r\n'
    'N;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:=D8=B1=D8=B6=D8=A7=DB=8C=DB=8C;=D8=B9=D9=84=DB=8C;;;\r\n'
    'FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:=D8=B9=D9=84=DB=8C =D8=B1=D8=B6=D8=A7=DB=8C=DB=8C\r\n'
    'TEL;CELL:0912 123 4567\r\n'
    'NOTE;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:100% =D8=AE=D9=88=D8=A8=\r\n'
    '=D8=B3=D8=B7=D8=B1=0A=D8=AF=D9=88=D9=85\r\n'
    'END:VCARD\r\n';

const _v3 =
    'BEGIN:VCARD\n'
    'VERSION:3.0\n'
    'FN:Sara\n'
    'TEL;TYPE=WORK:+98 21 8888 7777\n'
    'EMAIL:sara@example.com\n'
    'END:VCARD\n';

void main() {
  group('VcfFile.parse', () {
    test('reads several cards from one file', () {
      final result = VcfFile.parse(_bytes('$_android21$_v3'));
      expect(result.contacts, hasLength(2));
      expect(result.unreadable, 0);
    });

    test('decodes quoted-printable Persian, soft breaks and a literal %', () {
      final contact = VcfFile.parse(_bytes(_android21)).contacts.single;
      expect(contact.displayName, 'علی رضایی');
      expect(contact.name.first, 'علی');
      expect(contact.name.last, 'رضایی');
      expect(contact.phones.single.number, '0912 123 4567');
      expect(contact.notes.single.note, '100% خوبسطر\nدوم');
    });

    test('a card with only FN still gets a name to write', () {
      final contact = VcfFile.parse(_bytes(_v3)).contacts.single;
      expect(contact.name.first, 'Sara');
      expect(contact.emails.single.address, 'sara@example.com');
    });

    test('tolerates a byte-order mark', () {
      expect(VcfFile.parse(_bytes('﻿$_v3')).contacts, hasLength(1));
    });

    test('a file that is not a vCard holds no contacts', () {
      final result = VcfFile.parse(_bytes('hello\nworld\n'));
      expect(result.contacts, isEmpty);
      expect(result.unreadable, 0);
    });

    test('an empty card is counted as unreadable', () {
      final result = VcfFile.parse(
        _bytes('BEGIN:VCARD\nVERSION:3.0\nEND:VCARD\n$_v3'),
      );
      expect(result.contacts, hasLength(1));
      expect(result.unreadable, 1);
    });

    test('a card that would cross the provider batch limit is refused', () {
      final phones = List.generate(
        VcfFile.maxFields + 1,
        (i) => 'TEL:0912000$i',
      ).join('\n');
      final result = VcfFile.parse(
        _bytes('BEGIN:VCARD\nVERSION:3.0\nFN:X\n$phones\nEND:VCARD\n'),
      );
      expect(result.contacts, isEmpty);
      expect(result.unreadable, 1);
    });

    test('a photo too large for one binder call is dropped', () {
      final photo = base64.encode(Uint8List(VcfFile.maxPhotoBytes + 3));
      final contact = VcfFile.parse(
        _bytes(
          'BEGIN:VCARD\nVERSION:3.0\nFN:X\nTEL:09121234567\n'
          'PHOTO;ENCODING=b;TYPE=JPEG:$photo\nEND:VCARD\n',
        ),
      ).contacts.single;
      expect(contact.photo, isNull);
      expect(contact.phones, hasLength(1));
    });

    test('reads back what the plugin writes', () {
      final card = Contact(
        displayName: 'مریم',
        name: Name(first: 'مریم'),
        phones: [Phone('09121112233')],
      ).toVCard();
      final contact = VcfFile.parse(_bytes(card)).contacts.single;
      expect(contact.name.first, 'مریم');
      expect(contact.phones.single.number, '09121112233');
    });
  });

  group('VcfFile.duplicates', () {
    Contact withPhone(String number) =>
        Contact(displayName: 'x', phones: [Phone(number)]);

    test('the same number in another format is a duplicate', () {
      final flags = VcfFile.duplicates(
        [withPhone('+98 912 123 4567'), withPhone('09351112233')],
        knownNumbers: {'09121234567'},
        knownNames: const {},
      );
      expect(flags, [true, false]);
    });

    test('a number repeated inside the file is flagged the second time', () {
      final flags = VcfFile.duplicates(
        [withPhone('09351112233'), withPhone('0935 111 2233')],
        knownNumbers: const {},
        knownNames: const {},
      );
      expect(flags, [false, true]);
    });

    test('with no number the folded name decides', () {
      final flags = VcfFile.duplicates(
        [
          Contact(displayName: 'علي رضا'),
          Contact(displayName: 'سارا'),
        ],
        knownNumbers: const {},
        knownNames: {'علیرضا'},
      );
      expect(flags, [true, false]);
    });
  });

  test('a copy to the phone knows which accounts are already the phone', () {
    for (final type in ['', 'vnd.sec.contact.phone', 'com.android.huawei.phone']) {
      expect(ContactFileService.isPhoneAccountType(type), isTrue);
    }
    for (final type in ['com.google', 'com.whatsapp']) {
      expect(ContactFileService.isPhoneAccountType(type), isFalse);
    }
  });

  test('a name a SIM refuses is tried shorter', () {
    expect(ContactFileService.simNames('علی'), ['علی']);
    expect(ContactFileService.simNames('Ali 1060 Sadeghi'), [
      'Ali 1060 Sadeghi',
      'Ali 1060 Sadeg',
      'Ali 10',
    ]);
  });

  test('a SIM gets a number it accepts', () {
    expect(SimContactsService.simNumber('091-385-78667'), '09138578667');
    expect(SimContactsService.simNumber('+98 912 123 4567'), '+989121234567');
    expect(SimContactsService.simNumber('۰۹۱۲ ۱۲۳'), '0912123');
    expect(SimContactsService.simNumber('---'), '');
  });

  group('ContactSaveTarget', () {
    test('survives storage', () {
      for (final target in const [
        ContactSaveTarget.phone(),
        ContactSaveTarget.sim(3),
        ContactSaveTarget.account('com.google', 'a|b@example.com'),
      ]) {
        expect(ContactSaveTarget.decode(target.encode()), target);
      }
    });

    test('anything else is no target', () {
      for (final stored in [null, '', 'sim:x', 'account:', 'account:a|']) {
        expect(ContactSaveTarget.decode(stored), isNull);
      }
    });
  });
}
