import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
// SQLCipher's API types — the key bank lives only in `secure.db`.
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import '../services/sms_crypto_service.dart';
import 'secure_store.dart';

/// Lowercase hex — how every key and authority id is stored.
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
  /// The first key of this phone from that authority.
  added,

  /// It replaced the key this phone held from that authority — a new number,
  /// or a new generation («گوشی گم شد» in the issuance panel).
  replaced,

  /// This very key is already here.
  alreadyImported,

  /// An older generation of the key held for the same number — refused: the
  /// authority has since replaced it.
  older,
}

/// One of this phone's own keys, as the key bank screen shows it — public
/// data only.
class OwnKeySummary extends Equatable {
  const OwnKeySummary({
    required this.keyId,
    required this.authorityId,
    required this.phone,
    required this.generation,
    required this.importedAt,
  });
  final String keyId;
  final String authorityId;

  /// The number the certificate names (canonical, `09…`).
  final String phone;
  final int generation;

  /// When it was imported (ms since epoch).
  final int importedAt;

  @override
  List<Object?> get props => [
    keyId,
    authorityId,
    phone,
    generation,
    importedAt,
  ];
}

/// Everything the key bank screen shows — no secret ever leaves the
/// repository in a snapshot.
class KeyBankSnapshot extends Equatable {
  const KeyBankSnapshot({this.keys = const []});
  final List<OwnKeySummary> keys;

  bool get isEmpty => keys.isEmpty;

  @override
  List<Object?> get props => [keys];
}

/// A stored own key with its secret, for the encrypted-SMS path.
class StoredOwnKey {
  const StoredOwnKey({
    required this.keyId,
    required this.authorityId,
    required this.secret,
    required this.cert,
  });
  final String keyId;
  final String authorityId;
  final Uint8List secret;

  /// The member certificate (`MemberCert`), 103 bytes.
  final Uint8List cert;
}

/// «بانک کلید» storage, in `secure.db` (the table made by [SecureStore]).
///
/// It holds this phone's own keys only — one per authority, each with the
/// certificate that names it. Nobody else's key, number or name is ever
/// stored here: who a colleague is, is learned from their certificate when
/// they answer (`CertHandshake`).
///
/// Works only while the secure section is open; otherwise every call throws
/// [KeyBankLockedException]. Secrets are written and read here and nowhere
/// else.
class KeyBankRepository {
  KeyBankRepository({cipher.Database? Function()? database})
    : _database = database ?? (() => SecureStore.instance.database);

  final cipher.Database? Function() _database;

  cipher.Database get _db =>
      _database() ?? (throw const KeyBankLockedException());

  Future<KeyBankSnapshot> snapshot() async {
    final rows = await _db.query(
      'kb_own_keys',
      columns: ['key_id', 'authority_id', 'phone', 'generation', 'imported_at'],
      orderBy: 'imported_at',
    );
    return KeyBankSnapshot(
      keys: [
        for (final r in rows)
          OwnKeySummary(
            keyId: r['key_id'] as String,
            authorityId: r['authority_id'] as String,
            phone: r['phone'] as String,
            generation: r['generation'] as int,
            importedAt: r['imported_at'] as int,
          ),
      ],
    );
  }

  /// Stores a verified key file (see [KeyImportOutcome]).
  Future<KeyImportOutcome> importKeyFile(
    OpenedKeyFile opened, {
    DateTime? now,
  }) async {
    final authority = keyHex(opened.authorityId);
    final cert = opened.cert;
    final keyId = keyHex(cert.keyId);
    return _db.transaction((txn) async {
      final existing = await txn.query(
        'kb_own_keys',
        columns: ['key_id', 'phone', 'generation'],
        where: 'authority_id = ?',
        whereArgs: [authority],
      );
      if (existing.isNotEmpty) {
        final stored = existing.single;
        if (stored['key_id'] == keyId) return KeyImportOutcome.alreadyImported;
        if (stored['phone'] == cert.phone &&
            (stored['generation'] as int) > cert.generation) {
          return KeyImportOutcome.older;
        }
      }
      await txn.insert('kb_own_keys', {
        'authority_id': authority,
        'key_id': keyId,
        'phone': cert.phone,
        'generation': cert.generation,
        'secret': opened.secret,
        'cert': cert.cert,
        'imported_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
      }, conflictAlgorithm: cipher.ConflictAlgorithm.replace);
      return existing.isEmpty
          ? KeyImportOutcome.added
          : KeyImportOutcome.replaced;
    });
  }

  Future<void> removeKey(String keyId) =>
      _db.delete('kb_own_keys', where: 'key_id = ?', whereArgs: [keyId]);

  /// This phone's own keys, with their secrets and certificates.
  Future<List<StoredOwnKey>> ownKeys() async {
    final rows = await _db.query('kb_own_keys', orderBy: 'imported_at');
    return [
      for (final r in rows)
        StoredOwnKey(
          keyId: r['key_id'] as String,
          authorityId: r['authority_id'] as String,
          secret: r['secret'] as Uint8List,
          cert: r['cert'] as Uint8List,
        ),
    ];
  }
}
