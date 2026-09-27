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

  /// v1: `secure_meta` (phase C). v2: the key bank (phase E). v3: encrypted
  /// conversations (phase F).
  static const int _schemaVersion = 3;

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

  /// The schema on a database the tests open themselves (ffi, no SQLCipher).
  @visibleForTesting
  static Future<void> createSchemaForTest(cipher.Database db) =>
      _onCreate(db, _schemaVersion);

  /// Runs the migrations from [from] to the current version.
  @visibleForTesting
  static Future<void> upgradeSchemaForTest(cipher.Database db, int from) =>
      _onUpgrade(db, from, _schemaVersion);

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
    await _createKeyBank(db);
    await _createSecureMessages(db);
  }

  /// Encrypted conversations (v3) — see `SecureMessageStore`, the only code
  /// that reads or writes these tables.
  static Future<void> _createSecureMessages(cipher.DatabaseExecutor db) async {
    // One conversation per peer number (canonical). The peer's key and the
    // identity of ours used with them are fixed when it is started, so a key
    // bank change can never silently re-route an existing conversation.
    await db.execute('''
      CREATE TABLE sm_conversations (
        phone TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        peer_key_id TEXT NOT NULL,
        peer_public BLOB NOT NULL,
        own_key_id TEXT NOT NULL,
        own_source TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_at INTEGER NOT NULL,
        unread INTEGER NOT NULL DEFAULT 0,
        seen_sid INTEGER,
        seen_counter INTEGER
      )
    ''');
    // Ratchet states and our pending handshakes. Stored BEFORE the SMS that
    // used them goes out, so a crash can never reuse a message key.
    await db.execute('''
      CREATE TABLE sm_sessions (
        phone TEXT NOT NULL,
        sid INTEGER NOT NULL,
        pending INTEGER NOT NULL,
        state BLOB NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (phone, sid)
      )
    ''');
    // `sid`/`counter`: the session and counter the message travelled with —
    // what a «دیده شد» or «حذف برای هر دو» names it by.
    await db.execute('''
      CREATE TABLE sm_messages (
        id TEXT PRIMARY KEY,
        phone TEXT NOT NULL,
        outgoing INTEGER NOT NULL,
        body TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        status TEXT NOT NULL,
        sid INTEGER,
        counter INTEGER,
        delete_after_seen INTEGER NOT NULL DEFAULT 0,
        seen_at INTEGER,
        parts INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX sm_messages_thread ON sm_messages (phone, timestamp)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX sm_messages_wire ON sm_messages '
      '(phone, outgoing, sid, counter) WHERE sid IS NOT NULL',
    );
    // Packets taken from the main database's `secure_queue` that cannot be
    // processed yet (a message that arrived before its session's handshake).
    await db.execute('''
      CREATE TABLE sm_inbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        address TEXT NOT NULL,
        body TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        received_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        UNIQUE (address, body)
      )
    ''');
  }

  /// «بانک کلید» (v2) — see `KeyBankRepository`, the only code that reads
  /// or writes these tables.
  ///
  /// Every phone number here is canonical (`SmsCryptoService.canonicalPhone`
  /// — the same spelling the keys are derived from), and every id is
  /// lowercase hex.
  static Future<void> _createKeyBank(cipher.DatabaseExecutor db) async {
    // One row per organization directory; `signed` is the directory exactly
    // as the authority signed it, so it can be verified again at any time.
    await db.execute('''
      CREATE TABLE kb_directories (
        id TEXT PRIMARY KEY,
        authority_id TEXT NOT NULL,
        name TEXT NOT NULL,
        serial INTEGER NOT NULL,
        signed BLOB NOT NULL,
        imported_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE kb_members (
        directory_id TEXT NOT NULL,
        key_id TEXT NOT NULL,
        name TEXT NOT NULL,
        public_key BLOB NOT NULL,
        PRIMARY KEY (directory_id, key_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE kb_member_phones (
        phone TEXT NOT NULL,
        directory_id TEXT NOT NULL,
        key_id TEXT NOT NULL,
        PRIMARY KEY (phone, directory_id)
      )
    ''');
    // This phone's own identity in a directory — the one private key a key
    // file carries.
    await db.execute('''
      CREATE TABLE kb_own_keys (
        directory_id TEXT PRIMARY KEY,
        key_id TEXT NOT NULL,
        secret BLOB NOT NULL,
        public_key BLOB NOT NULL
      )
    ''');
    // A passphrase group: `seed` is the Argon2id result, i.e. the group's
    // secret; the passphrase itself is never stored.
    await db.execute('''
      CREATE TABLE kb_groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        seed BLOB NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    // This phone's own numbers: in a passphrase group a member's key is
    // derived from their number, so the app must know which numbers are ours.
    await db.execute('''
      CREATE TABLE kb_own_numbers (
        phone TEXT PRIMARY KEY,
        added_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _onUpgrade(
    cipher.Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) await _createKeyBank(db);
    if (oldVersion < 3) await _createSecureMessages(db);
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
