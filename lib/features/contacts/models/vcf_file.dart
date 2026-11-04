import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_contacts/flutter_contacts.dart';

import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/search_text.dart';

/// What a `.vcf` file held.
class VcfParseResult {
  const VcfParseResult(this.contacts, this.unreadable);

  final List<Contact> contacts;

  /// Cards that were skipped: nothing usable in them, or too large to write.
  final int unreadable;
}

/// Reads a vCard file (2.1, 3.0 or 4.0) into plugin [Contact]s.
///
/// The plugin parses one card. Everything before that is here: splitting the
/// file, and decoding quoted-printable. Android writes vCard 2.1, where every
/// Persian name is quoted-printable, and the plugin's own decoding throws on a
/// value holding a literal `%` and misses a soft line break.
class VcfFile {
  const VcfFile._();

  /// A contact is written in one batch of about one operation per field, and
  /// the provider refuses a batch of 500 (through the plugin, by killing the
  /// process). Well below that, whatever a file claims.
  static const int maxFields = 300;

  /// A photo travels in a single binder transaction, whose limit is 1 MB. The
  /// plugin does not catch that failure either.
  static const int maxPhotoBytes = 512 * 1024;

  static VcfParseResult parse(Uint8List bytes) {
    final cards = split(utf8.decode(bytes, allowMalformed: true));
    final contacts = <Contact>[];
    var unreadable = 0;
    for (final card in cards) {
      final contact = _read(card);
      if (contact == null) {
        unreadable++;
      } else {
        contacts.add(contact);
      }
    }
    return VcfParseResult(contacts, unreadable);
  }

  /// One normalized string per `BEGIN:VCARD … END:VCARD` in [text].
  static List<String> split(String text) {
    final lines = text
        .replaceFirst('﻿', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final cards = <String>[];
    StringBuffer? card;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      final upper = line.trim().toUpperCase();
      if (upper == 'BEGIN:VCARD') {
        card = StringBuffer()..writeln('BEGIN:VCARD');
        continue;
      }
      if (card == null) continue;
      if (upper == 'END:VCARD') {
        card.writeln('END:VCARD');
        cards.add(card.toString());
        card = null;
        continue;
      }
      if (_isQuotedPrintable(line)) {
        // A trailing «=» continues the value on the next line.
        while (line.trimRight().endsWith('=') && i + 1 < lines.length) {
          line = line.trimRight();
          line = line.substring(0, line.length - 1) + lines[++i].trimLeft();
        }
        line = _decodeLine(line);
      }
      card.writeln(line);
    }
    return cards;
  }

  /// The numbers of [contacts] that [knownNumbers] (canonical, see
  /// [PhoneNormalizer.toThreadId]) or an earlier card already has; for a card
  /// with no number, the same by folded name. One flag per contact.
  static List<bool> duplicates(
    List<Contact> contacts, {
    required Set<String> knownNumbers,
    required Set<String> knownNames,
  }) {
    final numbers = {...knownNumbers};
    final names = {...knownNames};
    final out = <bool>[];
    for (final contact in contacts) {
      final keys = [
        for (final phone in contact.phones)
          PhoneNormalizer.toThreadId(phone.number),
      ].where((k) => k.isNotEmpty).toList();
      if (keys.isNotEmpty) {
        out.add(keys.any(numbers.contains));
        numbers.addAll(keys);
      } else {
        final name = SearchText.foldTight(contact.displayName);
        out.add(name.isNotEmpty && names.contains(name));
        if (name.isNotEmpty) names.add(name);
      }
    }
    return out;
  }

  static Contact? _read(String card) {
    final Contact contact;
    try {
      contact = Contact.fromVCard(card);
    } catch (_) {
      return null;
    }
    final fields =
        contact.phones.length +
        contact.emails.length +
        contact.addresses.length +
        contact.organizations.length +
        contact.websites.length +
        contact.socialMedias.length +
        contact.events.length +
        contact.notes.length;
    if (fields > maxFields) return null;

    final name = contact.name;
    final hasName =
        name.first.isNotEmpty ||
        name.last.isNotEmpty ||
        name.middle.isNotEmpty ||
        name.nickname.isNotEmpty;
    if (!hasName && contact.displayName.isNotEmpty) {
      name.first = contact.displayName;
    }
    if (contact.displayName.isEmpty) {
      contact.displayName = [
        name.first,
        name.middle,
        name.last,
      ].where((p) => p.isNotEmpty).join(' ');
    }
    if (contact.displayName.isEmpty &&
        contact.phones.isEmpty &&
        contact.emails.isEmpty) {
      return null;
    }
    if ((contact.photo?.length ?? 0) > maxPhotoBytes) contact.photo = null;
    return contact;
  }

  static bool _isQuotedPrintable(String line) {
    final colon = line.indexOf(':');
    if (colon <= 0) return false;
    return line.substring(0, colon).toUpperCase().contains('QUOTED-PRINTABLE');
  }

  /// Decodes the value and drops the parameters that described its encoding.
  static String _decodeLine(String line) {
    final colon = line.indexOf(':');
    final head = line
        .substring(0, colon)
        .split(';')
        .where((p) {
          final upper = p.toUpperCase();
          return upper != 'QUOTED-PRINTABLE' &&
              upper != 'ENCODING=QUOTED-PRINTABLE' &&
              !upper.startsWith('CHARSET=');
        })
        .join(';');
    final value = _decodeQuotedPrintable(line.substring(colon + 1));
    return '$head:${value.replaceAll('\r\n', r'\n').replaceAll('\n', r'\n')}';
  }

  static String _decodeQuotedPrintable(String input) {
    final out = <int>[];
    final bytes = utf8.encode(input);
    for (var i = 0; i < bytes.length; i++) {
      final byte = bytes[i];
      if (byte == 0x3D && i + 2 < bytes.length) {
        final value = int.tryParse(
          String.fromCharCodes(bytes, i + 1, i + 3),
          radix: 16,
        );
        if (value != null) {
          out.add(value);
          i += 2;
          continue;
        }
      }
      out.add(byte);
    }
    return utf8.decode(out, allowMalformed: true);
  }
}
