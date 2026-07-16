import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import '../models/contact_model.dart';

/// Top-level function for isolate: maps serialized contact maps to output maps (with avatar_base64).
List<Map<String, dynamic>> _mapContactsInIsolate(
  List<Map<String, dynamic>> serialized,
) {
  return serialized
      .map((m) {
        final phones =
            (m['phones'] as List<dynamic>?)
                ?.map((e) => e as String)
                .where((p) => p.isNotEmpty)
                .toList() ??
            [];
        final primary = phones.isNotEmpty ? phones.first : '';
        if (primary.isEmpty) return null;
        final name = (m['name'] as String?)?.isNotEmpty == true
            ? m['name']!
            : 'بدون نام';
        return <String, dynamic>{
          'id': m['id'] as String? ?? '',
          'name': name,
          'phone_number': primary,
          'phone_numbers': phones,
          'email': m['email'] as String?,
          'avatar_base64': m['avatar_base64'] as String?,
        };
      })
      .whereType<Map<String, dynamic>>()
      .toList();
}

class ContactRepository {
  static List<ContactModel>? _cache;

  /// In-flight device read; concurrent callers await the same future instead
  /// of busy-waiting on a polling loop.
  static Completer<void>? _loading;

  /// Invalidate the cache to force a reload on next request
  void invalidateCache() {
    _cache = null;
  }

  Future<bool> _ensurePermission() async {
    return device_contacts.FlutterContacts.requestPermission();
  }

  Future<List<ContactModel>> getDeviceContacts({bool forceRefresh = false}) async {
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

      // Thumbnails only: full-resolution photos for an entire address book are
      // megabytes of decode work. The detail screen fetches the full photo for
      // its single contact separately.
      final contacts = await device_contacts.FlutterContacts.getContacts(
        withProperties: true,
        withThumbnail: true,
      );

      // Serialize for isolate (minimal data; photos as base64)
      final serialized = <Map<String, dynamic>>[];
      for (final c in contacts) {
        final phones = c.phones
            .map((p) => p.number)
            .where((p) => p.isNotEmpty)
            .toList();
        if (phones.isEmpty) continue;
        final avatar = c.thumbnail ?? c.photo;
        serialized.add({
          'id': c.id,
          'name': c.displayName,
          'phones': phones,
          'email': c.emails.isNotEmpty ? c.emails.first.address : null,
          'avatar_base64': avatar != null ? base64Encode(avatar) : null,
        });
      }

      // Heavy mapping off main thread
      final mapped = await compute(_mapContactsInIsolate, serialized);

      // Quick pass on main thread: build ContactModels (decode base64)
      final now = DateTime.now();
      _cache = mapped
          .map(
            (m) => ContactModel(
              id: m['id'] as String,
              name: m['name'] as String,
              phoneNumber: m['phone_number'] as String,
              phoneNumbers: List<String>.from(m['phone_numbers'] as List),
              email: m['email'] as String?,
              createdAt: now,
              updatedAt: now,
              avatar: _decodeAvatar(m['avatar_base64'] as String?),
            ),
          )
          .toList();
      return _cache!;
    } finally {
      _loading = null;
      completer.complete();
    }
  }

  static Uint8List? _decodeAvatar(String? base64) {
    if (base64 == null || base64.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(base64));
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
    final normalizedQuery = digits.replaceAll(RegExp(r'[^\d]'), '');

    if (normalizedQuery.isEmpty) return [];

    return contacts.where((contact) {
      // Check if any phone number contains the digits sequence
      return contact.phoneNumbers.any((phone) {
        final normalizedPhone = phone.replaceAll(RegExp(r'[^\d]'), '');
        return normalizedPhone.contains(normalizedQuery);
      });
    }).toList();
  }
}
