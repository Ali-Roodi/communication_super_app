import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';

/// One encrypted SMS as the native receiver parked it: ciphertext only.
class QueuedPacket {
  const QueuedPacket({
    required this.id,
    required this.address,
    required this.body,
    required this.timestamp,
  });
  final int id;
  final String address;
  final String body;
  final int timestamp;
}

/// The main database's `secure_queue` (see [AppConstants.secureQueueTable]).
///
/// Only read to be emptied: `SecureMessenger` copies every row into the secure
/// section and then deletes it here, so the unencrypted database holds an
/// encrypted SMS only for as long as the section stays locked.
class SecureQueueRepository {
  SecureQueueRepository({DatabaseHelper? dbHelper})
    : _dbHelper = dbHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _dbHelper;

  Future<List<QueuedPacket>> all() async {
    final db = await _dbHelper.database;
    final rows = await db.query(AppConstants.secureQueueTable, orderBy: 'id');
    return [
      for (final r in rows)
        QueuedPacket(
          id: r['id'] as int,
          address: r['address'] as String,
          body: r['body'] as String,
          timestamp: r['timestamp'] as int,
        ),
    ];
  }

  Future<void> delete(Iterable<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _dbHelper.database;
    final list = ids.toList();
    await db.delete(
      AppConstants.secureQueueTable,
      where: 'id IN (${List.filled(list.length, '?').join(',')})',
      whereArgs: list,
    );
  }
}
