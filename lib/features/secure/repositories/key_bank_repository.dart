import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
// SQLCipher's API types — the key bank lives only in `secure.db`.
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import '../services/sms_crypto_service.dart';
import 'secure_store.dart';

/// Lowercase hex — how every key, directory and group id is stored.
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

  /// The same copy, now with this phone's own key (a directory-only file
  /// came first).
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

class GroupSummary extends Equatable {
  const GroupSummary({
    required this.id,
    required this.name,
    required this.createdAt,
  });
  final String id;
  final String name;
  final int createdAt;
  @override
  List<Object?> get props => [id, name, createdAt];
}

/// Everything the key bank screen shows — public data only; no secret ever
/// leaves the repository in a snapshot.
class KeyBankSnapshot extends Equatable {
  const KeyBankSnapshot({
    this.directories = const [],
    this.groups = const [],
    this.ownNumbers = const [],
  });
  final List<DirectorySummary> directories;
  final List<GroupSummary> groups;
  final List<String> ownNumbers;

  bool get isEmpty => directories.isEmpty && groups.isEmpty;

  @override
  List<Object?> get props => [directories, groups, ownNumbers];
}

/// A peer's public key as the key bank knows it.
class PeerKey {
  const PeerKey({
    required this.source,
    required this.name,
    required this.publicKey,
    required this.keyId,
  });

  /// `directory:<id>` or `group:<id>`.
  final String source;
  final String name;
  final Uint8List publicKey;
  final Uint8List keyId;
}

/// «بانک کلید» storage, in `secure.db` (tables made by [SecureStore]).
///
/// Works only while the secure section is open; otherwise every call throws
/// [KeyBankLockedException]. Secrets (own keys, group seeds) are written and
/// read here and nowhere else.
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
    final groups = await db.query(
      'kb_groups',
      columns: ['id', 'name', 'created_at'],
      orderBy: 'created_at',
    );
    final numbers = await db.query('kb_own_numbers', orderBy: 'added_at');
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
      groups: [
        for (final r in groups)
          GroupSummary(
            id: r['id'] as String,
            name: r['name'] as String,
            createdAt: r['created_at'] as int,
          ),
      ],
      ownNumbers: [for (final r in numbers) r['phone'] as String],
    );
  }

  /// Stores a verified key file (see [KeyImportOutcome]).
  Future<KeyImportOutcome> importKeyFile(
    OpenedKeyFile opened, {
    DateTime? now,
  }) async {
    final d = opened.directory;
    final id = keyHex(d.directoryId);
    final member = opened.member;
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
        if (member == null) return KeyImportOutcome.alreadyImported;
        final own = await txn.query(
          'kb_own_keys',
          columns: ['key_id'],
          where: 'directory_id = ?',
          whereArgs: [id],
        );
        if (own.isNotEmpty && own.first['key_id'] == keyHex(member.keyId)) {
          return KeyImportOutcome.alreadyImported;
        }
        await _storeOwnKey(txn, id, member);
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

      if (member != null) {
        await _storeOwnKey(txn, id, member);
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
    SmsIdentity member,
  ) => txn.insert('kb_own_keys', {
    'directory_id': directoryId,
    'key_id': keyHex(member.keyId),
    'secret': member.secret,
    'public_key': member.publicKey,
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

  /// False when the group is already in the bank.
  Future<bool> addGroup({
    required Uint8List groupId,
    required String name,
    required Uint8List seed,
    DateTime? now,
  }) async {
    final id = keyHex(groupId);
    final inserted = await _db.insert('kb_groups', {
      'id': id,
      'name': name.trim(),
      'seed': seed,
      'created_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
    }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);
    return inserted != 0;
  }

  Future<void> removeGroup(String id) =>
      _db.delete('kb_groups', where: 'id = ?', whereArgs: [id]);

  /// [phone] must be canonical. False when it is already listed.
  Future<bool> addOwnNumber(String phone, {DateTime? now}) async {
    final inserted = await _db.insert('kb_own_numbers', {
      'phone': phone,
      'added_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
    }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);
    return inserted != 0;
  }

  Future<void> removeOwnNumber(String phone) =>
      _db.delete('kb_own_numbers', where: 'phone = ?', whereArgs: [phone]);

  // ── Lookups for the encrypted-SMS path (phase F) ───────────────────────────

  /// Directory members who own [phone] (canonical).
  Future<List<PeerKey>> directoryKeysFor(String phone) async {
    final rows = await _db.rawQuery(
      '''
      SELECT m.directory_id, m.name, m.public_key, m.key_id
        FROM kb_member_phones p
        JOIN kb_members m ON m.directory_id = p.directory_id AND m.key_id = p.key_id
       WHERE p.phone = ?
      ''',
      [phone],
    );
    return [
      for (final r in rows)
        PeerKey(
          source: 'directory:${r['directory_id']}',
          name: r['name'] as String,
          publicKey: r['public_key'] as Uint8List,
          keyId: _unhex(r['key_id'] as String),
        ),
    ];
  }

  /// Every group's secret seed (for deriving member keys).
  Future<List<({String id, String name, Uint8List seed})>> groupSeeds() async {
    final rows = await _db.query('kb_groups', orderBy: 'created_at');
    return [
      for (final r in rows)
        (
          id: r['id'] as String,
          name: r['name'] as String,
          seed: r['seed'] as Uint8List,
        ),
    ];
  }

  /// This phone's own directory keys, with their secrets.
  Future<List<SmsIdentity>> ownDirectoryKeys() async {
    final rows = await _db.query('kb_own_keys');
    return [
      for (final r in rows)
        SmsIdentity(
          secret: r['secret'] as Uint8List,
          publicKey: r['public_key'] as Uint8List,
          keyId: _unhex(r['key_id'] as String),
        ),
    ];
  }

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
