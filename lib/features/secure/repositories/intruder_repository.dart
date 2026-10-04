import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import 'package:communication_super_app/features/hidden/services/sealing_key.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

import 'package:communication_super_app/features/security/services/security_bridge.dart';

/// One photo (or one failed attempt to take one) after wrong PIN entries.
class IntruderPhoto {
  const IntruderPhoto({
    required this.id,
    required this.takenAt,
    required this.camera,
    required this.failures,
    required this.hasPhoto,
  });

  final int id;
  final int takenAt;

  /// `front`, `back`, or `none` when no photo could be taken.
  final String camera;

  /// Wrong entries in a row when it was taken.
  final int failures;
  final bool hasPhoto;
}

/// «عکس از ورود ناموفق» (matrix row 32), the secure half: Kotlin seals each
/// photo to the section's key while the app is locked; this opens them into
/// `secure.db` (`ip_photos`) once the section is open, and deletes the
/// sealed files.
class IntruderRepository {
  IntruderRepository({
    cipher.Database? Function()? database,
    SecurityBridge bridge = const SecurityBridge(),
    SmsCryptoService crypto = const SmsCryptoService(),
    SealingKey? key,
  }) : _database = database ?? (() => SecureStore.instance.database),
       _bridge = bridge,
       _crypto = crypto,
       _key = key;

  final cipher.Database? Function() _database;
  final SecurityBridge _bridge;
  final SmsCryptoService _crypto;
  final SealingKey? _key;

  cipher.Database get db =>
      _database() ?? (throw const KeyBankLockedException());

  /// Moves what Kotlin sealed into the section; how many records came in.
  Future<int> collect() async {
    final files = await _bridge.intruderFiles();
    if (files.isEmpty) return 0;
    final secret = await (_key ?? SealingKey()).secret();
    var added = 0;
    if (secret != null) {
      final opened = await _crypto.openSealed(
        secret: secret,
        blobs: [for (final f in files) f.blob],
      );
      for (final plain in opened) {
        if (plain == null) continue; // sealed to a section since deleted
        final record = parse(plain);
        if (record == null) continue;
        added +=
            await db.insert('ip_photos', {
                  'taken_at': record.takenAt,
                  'camera': record.camera,
                  'failed_attempts': record.failures,
                  'jpeg': record.jpeg,
                }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore) >
                0
            ? 1
            : 0;
      }
    }
    // Only once stored: what does not open never will.
    await _bridge.deleteIntruderFiles([for (final f in files) f.name]);
    return added;
  }

  /// `[u32 header length] ‖ header JSON ‖ JPEG` — see `IntruderCamera.kt`.
  @visibleForTesting
  static ({int takenAt, String camera, int failures, Uint8List? jpeg})? parse(
    Uint8List plain,
  ) {
    if (plain.length < 4) return null;
    final n = (plain[0] << 24) | (plain[1] << 16) | (plain[2] << 8) | plain[3];
    if (n <= 0 || 4 + n > plain.length) return null;
    try {
      final header =
          jsonDecode(utf8.decode(plain.sublist(4, 4 + n)))
              as Map<String, Object?>;
      final rest = plain.sublist(4 + n);
      return (
        takenAt: (header['takenAt'] as num).toInt(),
        camera: header['camera'] as String,
        failures: (header['failures'] as num?)?.toInt() ?? 0,
        jpeg: rest.isEmpty ? null : Uint8List.fromList(rest),
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<IntruderPhoto>> list() async {
    final rows = await db.rawQuery('''
      SELECT id, taken_at, camera, failed_attempts, jpeg IS NOT NULL AS has_photo
        FROM ip_photos ORDER BY taken_at DESC, camera DESC
    ''');
    return [
      for (final r in rows)
        IntruderPhoto(
          id: r['id'] as int,
          takenAt: r['taken_at'] as int,
          camera: r['camera'] as String,
          failures: r['failed_attempts'] as int,
          hasPhoto: r['has_photo'] == 1,
        ),
    ];
  }

  Future<Uint8List?> photo(int id) async {
    final rows = await db.query(
      'ip_photos',
      columns: ['jpeg'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.first['jpeg'] as Uint8List?;
  }

  Future<void> deleteAt(int takenAt) =>
      db.delete('ip_photos', where: 'taken_at = ?', whereArgs: [takenAt]);

  Future<void> deleteAll() => db.delete('ip_photos');
}
