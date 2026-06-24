import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
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
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  static List<ContactModel>? _cache;
  static bool _isLoading = false;

  /// Invalidate the cache to force a reload on next request
  void invalidateCache() {
    _cache = null;
  }

  Future<bool> _ensurePermission() async {
    return device_contacts.FlutterContacts.requestPermission();
  }

  Future<List<ContactModel>> getDeviceContacts() async {
    if (_cache != null) return _cache!;

    if (_isLoading) {
      while (_isLoading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return _cache ?? [];
    }

    _isLoading = true;
    try {
      final hasPermission = await _ensurePermission();
      if (!hasPermission) {
        _cache = [];
        return _cache!;
      }

      final contacts = await device_contacts.FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: true,
      );

      // Serialize for isolate (minimal data; photos as base64)
      final serialized = <Map<String, dynamic>>[];
      for (final c in contacts) {
        final phones = c.phones
            .map((p) => p.number)
            .where((p) => p.isNotEmpty)
            .toList();
        if (phones.isEmpty) continue;
        serialized.add({
          'id': c.id,
          'name': c.displayName,
          'phones': phones,
          'email': c.emails.isNotEmpty ? c.emails.first.address : null,
          'avatar_base64': c.photo != null ? base64Encode(c.photo!) : null,
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
      _isLoading = false;
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

  Future<List<ContactModel>> getAllContacts() async {
    return getDeviceContacts();
  }

  Future<ContactModel?> getContactById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.contactsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return ContactModel.fromMap(maps.first);
  }

  Future<ContactModel?> getContactByPhoneNumber(String phoneNumber) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.contactsTable,
      where: 'phone_number = ?',
      whereArgs: [phoneNumber],
    );
    if (maps.isEmpty) return null;
    return ContactModel.fromMap(maps.first);
  }

  Future<String> createContact(ContactModel contact) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.contactsTable,
      contact.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    invalidateCache(); // Invalidate cache after creating
    return contact.id;
  }

  Future<void> updateContact(ContactModel contact) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.contactsTable,
      contact.copyWith(updatedAt: DateTime.now()).toMap(),
      where: 'id = ?',
      whereArgs: [contact.id],
    );
    invalidateCache(); // Invalidate cache after updating
  }

  Future<void> deleteContact(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.contactsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
    invalidateCache(); // Invalidate cache after deleting
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
