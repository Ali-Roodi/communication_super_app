import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

/// One row of `sealed_queue`, opened. [record] is null for a row that does
/// not open with this section's key (sealed before a reset) or is not JSON —
/// either way it can only be dropped.
class SealedEntry {
  const SealedEntry({required this.id, required this.record});
  final int id;
  final Map<String, Object?>? record;
}

/// The main database's `sealed_queue` (see [AppConstants.sealedQueueTable]):
/// hidden-phonebook calls and SMS Kotlin sealed while the section was locked.
///
/// Read only to be emptied — the caller stores what it opened in `secure.db`
/// and then [remove]s the rows, so a crash in between re-reads them (and
/// the stores deduplicate).
class SealedInbox {
  SealedInbox({
    DatabaseHelper? dbHelper,
    SmsCryptoService crypto = const SmsCryptoService(),
  }) : _dbHelper = dbHelper ?? DatabaseHelper.instance,
       _crypto = crypto;

  final DatabaseHelper _dbHelper;
  final SmsCryptoService _crypto;

  static const kindSms = 'sms';
  static const kindCall = 'call';

  Future<List<SealedEntry>> open(String kind, Uint8List secret) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.sealedQueueTable,
      where: 'kind = ?',
      whereArgs: [kind],
      orderBy: 'id',
    );
    if (rows.isEmpty) return const [];
    final opened = await _crypto.openSealed(
      secret: secret,
      blobs: [for (final r in rows) r['blob'] as Uint8List],
    );
    return [
      for (var i = 0; i < rows.length; i++)
        SealedEntry(id: rows[i]['id'] as int, record: _decode(opened[i])),
    ];
  }

  Future<void> remove(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.sealedQueueTable,
      where: 'id IN (${List.filled(list.length, '?').join(',')})',
      whereArgs: list,
    );
  }

  static Map<String, Object?>? _decode(Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map ? value.cast<String, Object?>() : null;
    } on FormatException {
      debugPrint('A sealed record is not JSON');
      return null;
    }
  }
}
