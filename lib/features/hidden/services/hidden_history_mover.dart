import 'package:flutter/foundation.dart';

import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';

typedef MovedSms = ({bool outgoing, String body, int timestamp});

/// Takes a newly hidden number's history out of the ordinary app: its SMS
/// out of the main database and `content://sms`, its calls out of the
/// mirrored call log. (The *system* call log is swept by Kotlin as soon as
/// the number's tag is set.)
///
/// The SMS are read first and handed to the secure section by the caller;
/// only then is anything deleted here — a crash in between leaves the history
/// in both places, never in neither.
class HiddenHistoryMover {
  HiddenHistoryMover({DatabaseHelper? dbHelper, NativeSmsService? sms})
    : _dbHelper = dbHelper ?? DatabaseHelper.instance,
      _sms = sms ?? NativeSmsService();

  final DatabaseHelper _dbHelper;
  final NativeSmsService _sms;

  /// The conversation with [phone] as the inbox shows it, oldest first.
  /// Rows the user deleted (tombstones) are not history any more.
  Future<List<MovedSms>> smsHistory(String phone) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.messagesTable,
      columns: ['type', 'body', 'timestamp'],
      where: 'thread_id = ? AND is_deleted = 0',
      whereArgs: [PhoneNormalizer.toThreadId(phone)],
      orderBy: 'timestamp',
    );
    return [
      for (final r in rows)
        (
          outgoing: r['type'] != 'received',
          body: r['body'] as String,
          timestamp: r['timestamp'] as int,
        ),
    ];
  }

  /// Deletes [phone]'s conversation everywhere outside the section: the
  /// provider (a no-op without the SMS role — the mirror then filters the
  /// rows natively), every local row **including tombstones** (they hold the
  /// text), the search index's folded copy, and the thread's pin / archive /
  /// SIM / unread marks.
  Future<void> purgeSms(String phone) async {
    final threadId = PhoneNormalizer.toThreadId(phone);
    try {
      await _sms.deleteSmsThreadFromProvider(phone);
    } catch (e) {
      debugPrint(
        'Provider delete for a hidden number failed: ${e.runtimeType}',
      );
    }
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      if (DatabaseHelper.messageSearchFtsReady) {
        await txn.rawDelete(
          'DELETE FROM ${AppConstants.messageSearchTable} WHERE rowid IN '
          '(SELECT rowid FROM ${AppConstants.messagesTable} WHERE thread_id = ?)',
          [threadId],
        );
      }
      await txn.delete(
        AppConstants.messagesTable,
        where: 'thread_id = ?',
        whereArgs: [threadId],
      );
      for (final table in const [
        AppConstants.pinnedThreadsTable,
        AppConstants.archivedThreadsTable,
        AppConstants.threadSimTable,
        AppConstants.unreadMarksTable,
      ]) {
        await txn.delete(table, where: 'thread_id = ?', whereArgs: [threadId]);
      }
    });
  }

  /// Deletes [phone]'s rows from the mirrored call log (`call_logs`). The
  /// numbers there are as the provider spelled them, so they are matched
  /// canonically.
  Future<void> purgeCalls(String phone) async {
    final target = PhoneNormalizer.toThreadId(phone);
    final db = await _dbHelper.database;
    final numbers = await db.rawQuery(
      'SELECT DISTINCT phone_number FROM ${AppConstants.callLogsTable}',
    );
    final matching = [
      for (final r in numbers)
        if (PhoneNormalizer.toThreadId(r['phone_number'] as String) == target)
          r['phone_number'] as String,
    ];
    if (matching.isEmpty) return;
    await db.delete(
      AppConstants.callLogsTable,
      where: 'phone_number IN (${List.filled(matching.length, '?').join(',')})',
      whereArgs: matching,
    );
  }
}
