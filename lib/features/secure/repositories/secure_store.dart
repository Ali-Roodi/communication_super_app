import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
// SQLCipher's own factory — never sqflite's global one (see pubspec.yaml).
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import '../services/hidden_bridge.dart';
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
/// `DatabaseHelper`.
class SecureStore {
  SecureStore({
    SecureVaultService vault = const SecureVaultService(),
    HiddenBridge hidden = const HiddenBridge(),
  }) : _vault = vault,
       _hidden = hidden;

  /// The one store the app uses. Shared on purpose: `AuthBloc` rekeys and
  /// resets it when the app PIN changes, and `SecureSessionBloc` holds its
  /// open database — two instances would each think the other's database was
  /// closed.
  static final SecureStore instance = SecureStore();

  final SecureVaultService _vault;
  final HiddenBridge _hidden;
  cipher.Database? _db;

  static const String fileName = 'secure.db';

  /// v1: `secure_meta` (phase C). v2: the key bank (phase E). v3: encrypted
  /// conversations (phase F). v4: the hidden phonebook, its calls, and plain
  /// SMS with hidden contacts (phase G). v5: encrypted groups (matrix row 14).
  static const int _schemaVersion = 5;

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

  /// Deletes the vault and the database. What they held is gone for good —
  /// and so is Kotlin's half of the hidden phonebook: with no phonebook,
  /// no number may stay hidden, and nothing sealed can be opened any more.
  Future<void> reset() async {
    await lock();
    await _deleteDatabaseFile();
    await _guard(_vault.destroy);
    await _hidden.forget();
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

  /// Runs the migrations from [from] to [to] (default: the current version).
  @visibleForTesting
  static Future<void> upgradeSchemaForTest(
    cipher.Database db,
    int from, {
    int to = _schemaVersion,
  }) => _onUpgrade(db, from, to);

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
    await _upgradeMessagesToV4(db);
    await _createHiddenPhonebook(db);
    await _createGroups(db);
  }

  /// Encrypted groups (v5) — see `SecureGroupStore`, the only code that
  /// reads or writes these tables.
  ///
  /// SMS has no multicast: a group message is one row here and one delivery
  /// per member, each sealed over that member's own session. That is also
  /// why `sm_conversations` gains `listed`: a group makes a one-to-one
  /// conversation (and a handshake) with every member, and those stay out of
  /// the list until something is said in them.
  static Future<void> _createGroups(cipher.DatabaseExecutor db) async {
    await db.execute(
      'ALTER TABLE sm_conversations ADD COLUMN listed INTEGER NOT NULL DEFAULT 1',
    );
    // `creator` null = this phone. `pending_info`: a message arrived before
    // the group's definition; the first definition then decides the creator.
    // `left`: the creator's newest definition no longer lists this phone.
    await db.execute('''
      CREATE TABLE sg_groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        mode INTEGER NOT NULL,
        version INTEGER NOT NULL,
        creator TEXT,
        pending_info INTEGER NOT NULL DEFAULT 0,
        left_group INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_at INTEGER NOT NULL,
        unread INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // Every member but the creator (a receiver adds the creator itself).
    // Creator side: `info_version` is the definition this member was last
    // sent; `removed` keeps a dropped member until they are told.
    await db.execute('''
      CREATE TABLE sg_members (
        group_id TEXT NOT NULL,
        phone TEXT NOT NULL,
        key_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        info_version INTEGER NOT NULL DEFAULT 0,
        removed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (group_id, phone)
      )
    ''');
    // `sender` null = ours. Incoming: `sid`/`counter` of the pairwise
    // session it came on (what a receipt or a delete names).
    await db.execute('''
      CREATE TABLE sg_messages (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        sender TEXT,
        body TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        status TEXT NOT NULL,
        sid INTEGER,
        counter INTEGER,
        delete_after_seen INTEGER NOT NULL DEFAULT 0,
        seen_at INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX sg_messages_thread ON sg_messages (group_id, timestamp)',
    );
    // One per member an outgoing group message goes to.
    await db.execute('''
      CREATE TABLE sg_deliveries (
        message_id TEXT NOT NULL,
        phone TEXT NOT NULL,
        status TEXT NOT NULL,
        sid INTEGER,
        counter INTEGER,
        parts INTEGER,
        PRIMARY KEY (message_id, phone)
      )
    ''');
    await db.execute(
      'CREATE INDEX sg_deliveries_phone ON sg_deliveries (phone, status)',
    );
  }

  /// v4 on the phase F tables: a conversation may have **no key** (a hidden
  /// contact without one talks in plain SMS), and a message may be plain.
  /// SQLite cannot drop a NOT NULL, so `sm_conversations` is rebuilt.
  static Future<void> _upgradeMessagesToV4(cipher.DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE sm_conversations_v4 (
        phone TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        peer_key_id TEXT,
        peer_public BLOB,
        own_key_id TEXT,
        own_source TEXT,
        created_at INTEGER NOT NULL,
        last_at INTEGER NOT NULL,
        unread INTEGER NOT NULL DEFAULT 0,
        seen_sid INTEGER,
        seen_counter INTEGER
      )
    ''');
    await db.execute('''
      INSERT INTO sm_conversations_v4
        SELECT phone, name, peer_key_id, peer_public, own_key_id, own_source,
               created_at, last_at, unread, seen_sid, seen_counter
          FROM sm_conversations
    ''');
    await db.execute('DROP TABLE sm_conversations');
    await db.execute(
      'ALTER TABLE sm_conversations_v4 RENAME TO sm_conversations',
    );
    // A plain (unencrypted) SMS with a hidden contact.
    await db.execute(
      'ALTER TABLE sm_messages ADD COLUMN plain INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// «دفترچه مخفی» (v4) — see `HiddenContactsRepository`, the only code
  /// that reads or writes these tables. Numbers are canonical, like
  /// everything else in this database.
  static Future<void> _createHiddenPhonebook(cipher.DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE hc_contacts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE hc_numbers (
        contact_id TEXT NOT NULL,
        phone TEXT NOT NULL,
        label TEXT,
        position INTEGER NOT NULL,
        PRIMARY KEY (contact_id, phone)
      )
    ''');
    await db.execute('CREATE INDEX hc_numbers_phone ON hc_numbers (phone)');
    // Calls with hidden numbers, moved out of the system call log. `call_type`
    // is the raw `CallLog.Calls.TYPE` — mapped in Dart like the mirror's.
    // UNIQUE: a row swept twice (sealed, then the delete failed) is one call.
    await db.execute('''
      CREATE TABLE hc_calls (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        phone TEXT NOT NULL,
        call_type INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        duration INTEGER,
        account TEXT,
        UNIQUE (phone, timestamp, call_type)
      )
    ''');
    await db.execute('CREATE INDEX hc_calls_time ON hc_calls (timestamp DESC)');
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
    if (oldVersion < 2 && newVersion >= 2) await _createKeyBank(db);
    if (oldVersion < 3 && newVersion >= 3) await _createSecureMessages(db);
    if (oldVersion < 4 && newVersion >= 4) {
      await _upgradeMessagesToV4(db);
      await _createHiddenPhonebook(db);
    }
    if (oldVersion < 5 && newVersion >= 5) await _createGroups(db);
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
