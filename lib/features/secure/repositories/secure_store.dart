import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
// SQLCipher's own factory — never sqflite's global one (see pubspec.yaml).
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import '../services/secure_vault_service.dart';

/// Why the secure store could not open.
class SecureStoreException implements Exception {
  const SecureStoreException(this.failure);
  final VaultFailure failure;
  @override
  String toString() => 'SecureStoreException($failure)';
}

/// The secure section's storage: the key vault plus `secure.db`, a separate
/// SQLCipher database opened with the vault's data key.
///
/// **Separate from the main database on purpose.** The main one is opened by
/// Kotlin while the app is dead (cold-start SMS receiver, scheduled worker,
/// notification reply) with no key available; nothing secret may ever be
/// written there. This one only exists, open, between an unlock and the next
/// lock.
///
/// Schema changes go through [_schemaVersion] / [_onUpgrade], exactly as in
/// `DatabaseHelper`. Later phases add their tables here (hidden phonebook,
/// encrypted messages, keys).
class SecureStore {
  SecureStore({SecureVaultService vault = const SecureVaultService()})
    : _vault = vault;

  /// The one store the app uses. Shared on purpose: `AuthBloc` rekeys and
  /// resets it when the app PIN changes, and `SecureSessionBloc` holds its
  /// open database — two instances would each think the other's database was
  /// closed.
  static final SecureStore instance = SecureStore();

  final SecureVaultService _vault;
  cipher.Database? _db;

  static const String fileName = 'secure.db';
  static const int _schemaVersion = 1;

  /// The open database, or null while locked.
  cipher.Database? get database => _db;

  bool get isOpen => _db != null;

  Future<bool> exists() => _vault.exists();

  /// Creates the vault and a fresh database, and leaves it open.
  Future<void> create(String pin) async {
    final keyHex = await _guard(() => _vault.create(pin));
    // A database left behind by an earlier vault can never be opened with
    // this key — and must not be mistaken for this one.
    await _deleteDatabaseFile();
    _db = await _open(keyHex);
  }

  /// Opens the vault with [pin] and the database with its key.
  Future<void> unlock(String pin) async {
    final keyHex = await _guard(() => _vault.unlock(pin));
    try {
      _db = await _open(keyHex);
    } on cipher.DatabaseException catch (e) {
      // The vault opened, so this key is right for the vault; a database it
      // cannot read is corrupt (or belongs to another vault).
      debugPrint('secure.db unreadable: ${e.runtimeType}');
      throw const SecureStoreException(VaultFailure.corrupt);
    }
  }

  Future<void> lock() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  /// Re-seals the data key under [newPin]. The database is untouched.
  Future<void> rekey(String oldPin, String newPin) =>
      _guard(() => _vault.rekey(oldPin, newPin));

  /// Deletes the vault and the database. What they held is gone for good.
  Future<void> reset() async {
    await lock();
    await _deleteDatabaseFile();
    await _guard(_vault.destroy);
  }

  Future<void> setSecureWindow(bool secure) => _vault.setSecureWindow(secure);

  Future<cipher.Database> _open(String keyHex) async {
    final path = await _path();
    return cipher.openDatabase(
      path,
      // SQLCipher raw-key syntax: the vault's 256-bit key is used as is,
      // instead of being stretched again by SQLCipher's own KDF.
      password: "x'$keyHex'",
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(cipher.Database db, int version) async {
    await db.execute('''
      CREATE TABLE secure_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.insert('secure_meta', {
      'key': 'created_at',
      'value': DateTime.now().millisecondsSinceEpoch.toString(),
    });
  }

  static Future<void> _onUpgrade(
    cipher.Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // No migrations yet — v1 is the first schema.
  }

  Future<String> _path() async =>
      p.join(await cipher.getDatabasesPath(), fileName);

  Future<void> _deleteDatabaseFile() async {
    final path = await _path();
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on VaultException catch (e) {
      throw SecureStoreException(e.failure);
    }
  }
}
