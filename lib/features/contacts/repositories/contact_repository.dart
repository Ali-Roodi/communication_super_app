import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
import '../models/contact_model.dart';

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

  ContactModel _mapDeviceContact(device_contacts.Contact contact) {
    final phones = contact.phones.map((p) => p.number).where((p) => p.isNotEmpty).toList();
    final primaryPhone = phones.isNotEmpty ? phones.first : '';
    Uint8List? avatar = contact.photo;

    return ContactModel(
      id: contact.id,
      name: contact.displayName.isNotEmpty ? contact.displayName : 'بدون نام',
      phoneNumber: primaryPhone,
      phoneNumbers: phones,
      email: contact.emails.isNotEmpty ? contact.emails.first.address : null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      avatar: avatar,
    );
  }

  Future<List<ContactModel>> getDeviceContacts() async {
    if (_cache != null) return _cache!;

    // Prevent duplicate parallel loads
    if (_isLoading) {
      // Wait briefly until loading completes
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

      _cache =
          contacts.map(_mapDeviceContact).where((c) => c.phoneNumber.isNotEmpty).toList();
      return _cache!;
    } finally {
      _isLoading = false;
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
        .where((c) =>
            c.name.toLowerCase().contains(lower) ||
            c.phoneNumbers.any((p) => p.toLowerCase().contains(lower)))
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

