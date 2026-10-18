import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
// SQLCipher's API types — the key bank lives only in `secure.db`.
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import '../services/sms_crypto_service.dart';
import 'secure_store.dart';

/// Lowercase hex — how every key and directory id is stored.
String keyHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The key bank was used while the secure section was locked.
class KeyBankLockedException implements Exception {
  const KeyBankLockedException();
  @override
  String toString() => 'KeyBankLockedException';
}

/// What importing a key file did.
enum KeyImportOutcome {
  /// A directory this phone did not have.
  added,

  /// A newer copy of a directory it had.
  updated,

  /// The same copy, now with this phone's own key (the update file came
  /// first).
  ownKeyAdded,

  /// Nothing new.
  alreadyImported,

  /// An older copy than the one stored — refused: it may still list a key the
  /// authority has since replaced.
  older,
}

class DirectorySummary extends Equatable {
  const DirectorySummary({
    required this.id,
    required this.authorityId,
    required this.name,
    required this.serial,
    required this.memberCount,
    this.ownName,
  });
  final String id;
  final String authorityId;
  final String name;

  /// The issue time the authority stamped (ms since epoch).
  final int serial;
  final int memberCount;

  /// This phone's own entry in the directory, when its key was imported.
  final String? ownName;

  bool get hasOwnKey => ownName != null;

  @override
  List<Object?> get props => [
    id,
    authorityId,
    name,
    serial,
    memberCount,
    ownName,
  ];
}

/// Everything the key bank screen shows — public data only; no secret ever
/// leaves the repository in a snapshot.
class KeyBankSnapshot extends Equatable {
  const KeyBankSnapshot({this.directories = const []});
  final List<DirectorySummary> directories;

  bool get isEmpty => directories.isEmpty;

  @override
  List<Object?> get props => [directories];
}

/// One member of a stored directory.
class DirectoryEntry {
  const DirectoryEntry({
    required this.directoryId,
    required this.directoryName,
    required this.keyId,
    required this.name,
    required this.publicKey,
    required this.phones,
  });
  final String directoryId;
  final String directoryName;

  /// The key id the member's certificate carries.
  final String keyId;
  final String name;

  /// The member's X25519 key.
  final Uint8List publicKey;

  /// Canonical.
  final List<String> phones;
}

/// A directory member who owns a number, as the key bank knows them.
class PeerKey {
  const PeerKey({
    required this.directoryId,
    required this.directoryName,
    required this.name,
    required this.publicKey,
    required this.keyId,
  });

  final String directoryId;
  final String directoryName;
  final String name;
  final Uint8List publicKey;
  final Uint8List keyId;
}

/// «بانک کلید» storage, in `secure.db` (tables made by [SecureStore]).
///
/// Works only while the secure section is open; otherwise every call throws
/// [KeyBankLockedException]. Secrets (own keys) are written and read here and
/// nowhere else.
class KeyBankRepository {
  KeyBankRepository({cipher.Database? Function()? database})
    : _database = database ?? (() => SecureStore.instance.database);

  final cipher.Database? Function() _database;

  cipher.Database get _db =>
      _database() ?? (throw const KeyBankLockedException());

  Future<KeyBankSnapshot> snapshot() async {
    final db = _db;
    final dirs = await db.rawQuery('''
      SELECT d.id, d.authority_id, d.name, d.serial,
             (SELECT COUNT(*) FROM kb_members m WHERE m.directory_id = d.id) AS members,
             (SELECT m.name FROM kb_own_keys o
                JOIN kb_members m ON m.directory_id = o.directory_id AND m.key_id = o.key_id
               WHERE o.directory_id = d.id) AS own_name
        FROM kb_directories d
       ORDER BY d.name COLLATE NOCASE
    ''');
    return KeyBankSnapshot(
      directories: [
        for (final r in dirs)
          DirectorySummary(
            id: r['id'] as String,
            authorityId: r['authority_id'] as String,
            name: r['name'] as String,
            serial: r['serial'] as int,
            memberCount: r['members'] as int,
            ownName: r['own_name'] as String?,
          ),
      ],
    );
  }

  /// Stores a verified key file (see [KeyImportOutcome]).
  Future<KeyImportOutcome> importKeyFile(
    OpenedKeyFile opened, {
    DateTime? now,
  }) async {
    final d = opened.directory;
    final id = keyHex(d.directoryId);
    final own = opened.own;
    return _db.transaction((txn) async {
      final existing = await txn.query(
        'kb_directories',
        columns: ['serial'],
        where: 'id = ?',
        whereArgs: [id],
      );
      final storedSerial = existing.isEmpty
          ? null
          : existing.first['serial'] as int;
      if (storedSerial != null && storedSerial > d.serial) {
        return KeyImportOutcome.older;
      }
      if (storedSerial == d.serial) {
        if (own == null) return KeyImportOutcome.alreadyImported;
        final stored = await txn.query(
          'kb_own_keys',
          columns: ['key_id'],
          where: 'directory_id = ?',
          whereArgs: [id],
        );
        if (stored.isNotEmpty &&
            stored.first['key_id'] == keyHex(own.identity.keyId)) {
          return KeyImportOutcome.alreadyImported;
        }
        await _storeOwnKey(txn, id, own);
        return KeyImportOutcome.ownKeyAdded;
      }

      await txn.delete(
        'kb_members',
        where: 'directory_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'kb_member_phones',
        where: 'directory_id = ?',
        whereArgs: [id],
      );
      await txn.insert('kb_directories', {
        'id': id,
        'authority_id': keyHex(d.authorityId),
        'name': d.name,
        'serial': d.serial,
        'signed': opened.signed,
        'imported_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
      }, conflictAlgorithm: cipher.ConflictAlgorithm.replace);
      final batch = txn.batch();
      for (final m in d.members) {
        final kid = keyHex(m.keyId);
        batch.insert('kb_members', {
          'directory_id': id,
          'key_id': kid,
          'name': m.name,
          'public_key': m.publicKey,
        });
        for (final phone in m.phones) {
          batch.insert('kb_member_phones', {
            'phone': phone,
            'directory_id': id,
            'key_id': kid,
          });
        }
      }
      await batch.commit(noResult: true);

      if (own != null) {
        await _storeOwnKey(txn, id, own);
      } else {
        // A newer directory without this phone's key: keep the stored key
        // only while the authority still lists it.
        await txn.rawDelete(
          '''
          DELETE FROM kb_own_keys WHERE directory_id = ? AND key_id NOT IN
            (SELECT key_id FROM kb_members WHERE directory_id = ?)
          ''',
          [id, id],
        );
      }
      return storedSerial == null
          ? KeyImportOutcome.added
          : KeyImportOutcome.updated;
    });
  }

  Future<void> _storeOwnKey(
    cipher.DatabaseExecutor txn,
    String directoryId,
    OwnKey own,
  ) => txn.insert('kb_own_keys', {
    'directory_id': directoryId,
    'key_id': keyHex(own.identity.keyId),
    'secret': own.identity.secret,
    'public_key': own.identity.publicKey,
    'cert': own.cert.cert,
  }, conflictAlgorithm: cipher.ConflictAlgorithm.replace);

  Future<void> removeDirectory(String id) => _db.transaction((txn) async {
    for (final table in const [
      'kb_members',
      'kb_member_phones',
      'kb_own_keys',
    ]) {
      await txn.delete(table, where: 'directory_id = ?', whereArgs: [id]);
    }
    await txn.delete('kb_directories', where: 'id = ?', whereArgs: [id]);
  });

  // ── Lookups for the encrypted-SMS path (phase F) ───────────────────────────

  /// Directory members who own [phone] (canonical).
  Future<List<PeerKey>> directoryKeysFor(String phone) async {
    final rows = await _db.rawQuery(
      '''
      SELECT m.directory_id, d.name AS directory_name, m.name, m.public_key,
             m.key_id
        FROM kb_member_phones p
        JOIN kb_members m ON m.directory_id = p.directory_id AND m.key_id = p.key_id
        JOIN kb_directories d ON d.id = m.directory_id
       WHERE p.phone = ?
      ''',
      [phone],
    );
    return [
      for (final r in rows)
        PeerKey(
          directoryId: r['directory_id'] as String,
          directoryName: r['directory_name'] as String,
          name: r['name'] as String,
          publicKey: r['public_key'] as Uint8List,
          keyId: _unhex(r['key_id'] as String),
        ),
    ];
  }

  /// This phone's own keys, with their secrets and the member certificate
  /// ([cert]) that names each.
  Future<List<({String directoryId, SmsIdentity identity, Uint8List cert})>>
  ownDirectoryKeys() async {
    final rows = await _db.query('kb_own_keys');
    return [
      for (final r in rows)
        (
          directoryId: r['directory_id'] as String,
          identity: SmsIdentity(
            secret: r['secret'] as Uint8List,
            publicKey: r['public_key'] as Uint8List,
            keyId: _unhex(r['key_id'] as String),
          ),
          cert: r['cert'] as Uint8List,
        ),
    ];
  }

  /// The name the directories give the holder of [phone], if any.
  Future<String?> nameFor(String phone) async {
    final rows = await _db.rawQuery(
      '''
      SELECT m.name FROM kb_member_phones p
        JOIN kb_members m ON m.directory_id = p.directory_id AND m.key_id = p.key_id
       WHERE p.phone = ? LIMIT 1
      ''',
      [phone],
    );
    return rows.isEmpty ? null : rows.first['name'] as String;
  }

  /// Every member of every directory — the people an encrypted conversation
  /// can be started with. Each member's phones come back **in the
  /// directory's order** (the order they were inserted): GROUP_CONCAT's own
  /// order is undefined, and it once put a member's landline first.
  Future<List<DirectoryEntry>> allMembers() async {
    final members = await _db.rawQuery('''
      SELECT m.directory_id, d.name AS directory_name, m.key_id, m.name,
             m.public_key
        FROM kb_members m
        JOIN kb_directories d ON d.id = m.directory_id
       ORDER BY m.name COLLATE NOCASE
    ''');
    final phones = <String, List<String>>{};
    for (final r in await _db.rawQuery(
      'SELECT directory_id, key_id, phone FROM kb_member_phones ORDER BY rowid',
    )) {
      phones
          .putIfAbsent('${r['directory_id']}/${r['key_id']}', () => [])
          .add(r['phone'] as String);
    }
    return [
      for (final r in members)
        DirectoryEntry(
          directoryId: r['directory_id'] as String,
          directoryName: r['directory_name'] as String,
          keyId: r['key_id'] as String,
          name: r['name'] as String,
          publicKey: r['public_key'] as Uint8List,
          phones: phones['${r['directory_id']}/${r['key_id']}'] ?? const [],
        ),
    ];
  }

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
