import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import '../models/contact_model.dart';
import '../models/phone_match.dart';

class ContactRepository {
  static List<ContactModel>? _cache;

  /// In-flight device read; concurrent callers await the same future instead
  /// of busy-waiting on a polling loop.
  static Completer<void>? _loading;

  /// Non-digit stripper reused across [filterContactsByPhoneDigits] calls
  /// instead of recompiling a RegExp per contact per keystroke.
  static final RegExp _nonDigits = RegExp(r'[^\d]');

  /// Invalidate the cache to force a reload on next request
  void invalidateCache() {
    _cache = null;
  }

  Future<bool> _ensurePermission() async {
    return device_contacts.FlutterContacts.requestPermission();
  }

  Future<List<ContactModel>> getDeviceContacts({
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) _cache = null;
    if (_cache != null) return _cache!;

    final inFlight = _loading;
    if (inFlight != null) {
      await inFlight.future;
      return _cache ?? [];
    }

    final completer = Completer<void>();
    _loading = completer;
    try {
      final hasPermission = await _ensurePermission();
      if (!hasPermission) {
        _cache = [];
        return _cache!;
      }

      // Names + numbers only. Avatars are intentionally NOT loaded here:
      // holding the decoded thumbnail of every contact permanently in this
      // static cache blew the heap on large address books (OOM kills / GC
      // thrash on aggressive-memory OEMs). Each visible row and the detail
      // screen fetch their own thumbnail lazily by id — see
      // [getContactThumbnail] / LazyContactAvatar.
      final contacts = await device_contacts.FlutterContacts.getContacts(
        withProperties: true,
        withThumbnail: false,
        withPhoto: false,
      );

      final now = DateTime.now();
      final list = <ContactModel>[];
      for (final c in contacts) {
        final phones = c.phones
            .map((p) => p.number)
            .where((p) => p.isNotEmpty)
            .toList();
        // Contacts without a number are kept: Google Contacts lists them too
        // (their call/message actions simply grey out). Call sites that *need*
        // a number — the SMS recipient picker, the favourites picker — filter
        // on `phoneNumbers` themselves.
        list.add(
          ContactModel(
            id: c.id,
            name: c.displayName.isNotEmpty ? c.displayName : 'بدون نام',
            phoneNumber: phones.isNotEmpty ? phones.first : '',
            phoneNumbers: phones,
            email: c.emails.isNotEmpty ? c.emails.first.address : null,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      _cache = list;
      return _cache!;
    } finally {
      _loading = null;
      completer.complete();
    }
  }

  /// Lazily fetches the thumbnail bytes for a single device contact by id.
  /// Returns null when the id is empty, the contact has no photo, or the read
  /// fails. Callers cache the result (see LazyContactAvatar).
  Future<Uint8List?> getContactThumbnail(String contactId) async {
    if (contactId.isEmpty) return null;
    try {
      final c = await device_contacts.FlutterContacts.getContact(
        contactId,
        withProperties: false,
        withThumbnail: true,
        withPhoto: false,
      );
      return c?.thumbnail;
    } catch (_) {
      return null;
    }
  }

  Future<List<ContactModel>> getAllContacts({bool forceRefresh = false}) async {
    return getDeviceContacts(forceRefresh: forceRefresh);
  }

  /// Resolves a device-contact display name for [phoneNumber] (E.164 or local
  /// format), matching on the normalized national number so `+98…` and `09…`
  /// both hit a contact saved either way. Returns null if no match.
  Future<String?> getDeviceContactName(String phoneNumber) async {
    final contact = await getContactByPhoneNumber(phoneNumber);
    return (contact == null || contact.name.isEmpty) ? null : contact.name;
  }

  /// Finds the device contact owning [phoneNumber], matching on the normalized
  /// national number across **all** of each contact's numbers, so `+98…` and
  /// `09…` both resolve.
  ///
  /// This used to query the local `contacts` SQLite table — which nothing
  /// writes to anymore — so it returned null for every device contact and
  /// messages lost their contact linkage. Now it reads the same device-contact
  /// cache the lists use.
  Future<ContactModel?> getContactByPhoneNumber(String phoneNumber) async {
    final target = PhoneNormalizer.toThreadId(phoneNumber);
    if (target.isEmpty) return null;
    final contacts = await getDeviceContacts();
    for (final c in contacts) {
      for (final p in [...c.phoneNumbers, c.phoneNumber]) {
        if (PhoneNormalizer.toThreadId(p) == target) return c;
      }
    }
    return null;
  }

  Future<List<ContactModel>> searchContacts(String query) async {
    final contacts = await getDeviceContacts();
    final lower = query.toLowerCase();
    return contacts
        .where(
          (c) =>
              c.name.toLowerCase().contains(lower) ||
              c.phoneNumbers.any((p) => p.toLowerCase().contains(lower)),
        )
        .toList();
  }

  /// Filters contacts by phone number digits (for dialer smart suggestions)
  /// Returns contacts whose phone numbers contain the given digits sequence
  List<ContactModel> filterContactsByPhoneDigits(
    List<ContactModel> contacts,
    String digits,
  ) {
    if (digits.isEmpty) return [];

    // Normalize the search query (remove non-digits)
    final normalizedQuery = digits.replaceAll(_nonDigits, '');

    if (normalizedQuery.isEmpty) return [];

    return contacts.where((contact) {
      // Check if any phone number contains the digits sequence
      return contact.phoneNumbers.any((phone) {
        final normalizedPhone = phone.replaceAll(_nonDigits, '');
        return normalizedPhone.contains(normalizedQuery);
      });
    }).toList();
  }

  /// Same match as [filterContactsByPhoneDigits], but resolved down to the
  /// individual numbers: a contact whose second number was typed yields that
  /// number, and a contact matching on two of its numbers yields both.
  ///
  /// This is what the dialer and the search screen render — showing the
  /// contact's first number instead would answer a search for one number with
  /// a different one.
  List<PhoneMatch> matchPhoneDigits(
    List<ContactModel> contacts,
    String digits,
  ) {
    final normalizedQuery = digits.replaceAll(_nonDigits, '');
    if (normalizedQuery.isEmpty) return [];

    final matches = <PhoneMatch>[];
    for (final contact in contacts) {
      for (final phone in contact.phoneNumbers) {
        final phoneDigits = phone.replaceAll(_nonDigits, '');
        final at = phoneDigits.indexOf(normalizedQuery);
        if (at < 0) continue;
        matches.add(
          PhoneMatch(
            contact: contact,
            number: phone,
            digits: phoneDigits,
            matchStart: at,
            matchLength: normalizedQuery.length,
          ),
        );
      }
    }
    return matches;
  }
}
