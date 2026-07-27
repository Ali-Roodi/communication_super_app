import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/favorites/models/favorite_model.dart';
import 'package:communication_super_app/features/favorites/repositories/favorites_repository.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';
import 'package:communication_super_app/features/messages/models/draft_model.dart';
import 'package:communication_super_app/features/messages/models/message_category_model.dart';
import 'package:communication_super_app/features/messages/repositories/draft_repository.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/call_history/repositories/call_log_repository.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';
import 'package:communication_super_app/features/messages/repositories/scheduled_message_repository.dart';

FavoriteModel _fav(String id, String number) => FavoriteModel(
  id: id,
  phoneNumber: number,
  normalized: FavoriteModel.normalize(number),
  createdAt: DateTime(2026, 1, 1),
);

BlockedNumberModel _blocked(String id, String number) => BlockedNumberModel(
  id: id,
  phoneNumber: number,
  normalized: BlockedNumberModel.normalize(number),
  createdAt: DateTime(2026, 1, 1),
);

MessageModel _message(
  String id, {
  String threadId = '09120000000',
  String body = 'سلام',
  int minute = 0,
  MessageType type = MessageType.received,
}) => MessageModel(
  id: id,
  threadId: threadId,
  phoneNumber: threadId,
  body: body,
  type: type,
  status: MessageStatus.delivered,
  timestamp: DateTime(2026, 1, 1, 12, minute),
);

CallLogModel _call(String id, {int minute = 0}) => CallLogModel(
  id: id,
  phoneNumber: '0912000$id',
  callType: CallType.incoming,
  timestamp: DateTime(2026, 1, 1, 12, minute),
);

ScheduledMessage _scheduled(
  String id, {
  required DateTime at,
  ScheduleStatus status = ScheduleStatus.pending,
}) => ScheduledMessage(
  id: id,
  phoneNumber: '0912000$id',
  body: 'سلام',
  scheduledAt: at,
  status: status,
  createdAt: DateTime(2026, 1, 1),
);

ContactModel _contact(
  String id, {
  String name = 'علی',
  String phone = '09120000000',
}) => ContactModel(
  id: id,
  name: name,
  phoneNumber: phone,
  phoneNumbers: [phone],
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  setUpAll(() {
    // Run the real schema/migrations against an in-memory SQLite database.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
  });

  // Fresh, empty database for every test.
  setUp(() => DatabaseHelper.resetForTesting());
  tearDownAll(() => DatabaseHelper.resetForTesting());

  group('FavoritesRepository', () {
    test('add then read returns the favorite', () async {
      final repo = FavoritesRepository();
      await repo.addFavorite(_fav('1', '09120000000'));

      final all = await repo.getFavorites();
      expect(all, hasLength(1));
      expect(all.single.normalized, '09120000000');
    });

    test('duplicate normalized number is ignored (UNIQUE index)', () async {
      final repo = FavoritesRepository();
      await repo.addFavorite(_fav('1', '0912 000 0000'));
      await repo.addFavorite(_fav('2', '09120000000')); // same digits

      expect(await repo.getFavorites(), hasLength(1));
    });

    test('isFavorite reflects add / remove', () async {
      final repo = FavoritesRepository();
      await repo.addFavorite(_fav('1', '09120000000'));
      expect(await repo.isFavorite('09120000000'), isTrue);

      await repo.removeFavorite('09120000000');
      expect(await repo.isFavorite('09120000000'), isFalse);
      expect(await repo.getFavorites(), isEmpty);
    });
  });

  group('BlockedNumbersRepository', () {
    test('block then read returns the number', () async {
      final repo = BlockedNumbersRepository();
      await repo.block(_blocked('1', '09121112233'));

      final all = await repo.getBlocked();
      expect(all, hasLength(1));
      expect(all.single.normalized, '09121112233');
    });

    test('isBlocked reflects block / unblock', () async {
      final repo = BlockedNumbersRepository();
      await repo.block(_blocked('1', '09121112233'));
      expect(await repo.isBlocked('09121112233'), isTrue);

      await repo.unblock('09121112233');
      expect(await repo.isBlocked('09121112233'), isFalse);
    });

    test('favorites and blocked numbers are independent tables', () async {
      final favorites = FavoritesRepository();
      final blocked = BlockedNumbersRepository();
      await favorites.addFavorite(_fav('1', '09120000000'));
      await blocked.block(_blocked('2', '09120000000'));

      expect(await favorites.getFavorites(), hasLength(1));
      expect(await blocked.getBlocked(), hasLength(1));
    });
  });

  group('MessageRepository', () {
    test(
      'getMessagesByThread returns messages in chronological order',
      () async {
        final repo = MessageRepository();
        await repo.createMessage(_message('m1', minute: 0, body: 'اول'));
        await repo.createMessage(_message('m2', minute: 5, body: 'دوم'));

        final msgs = await repo.getMessagesByThread('09120000000');
        expect(msgs.map((m) => m.body), ['اول', 'دوم']);
      },
    );

    test('duplicate content (phone, body, timestamp, type) is ignored (DB-v3 '
        'unique index)', () async {
      final repo = MessageRepository();
      // Same content, different id — mimics live-received vs. later-imported.
      await repo.createMessage(_message('live-uuid', body: 'تکراری'));
      await repo.createMessage(_message('imported-99', body: 'تکراری'));

      expect(await repo.getMessagesByThread('09120000000'), hasLength(1));
    });

    test('softDeleteMessages hides messages from the thread query', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('m1', minute: 0));
      await repo.createMessage(_message('m2', minute: 5));

      await repo.softDeleteMessages(['m1']);

      final remaining = await repo.getMessagesByThread('09120000000');
      expect(remaining.map((m) => m.id), ['m2']);
    });

    test('getAllThreads returns one thread even when the two newest messages '
        'share a timestamp', () async {
      final repo = MessageRepository();
      // Two messages at the same millisecond (multipart SMS / burst delivery).
      await repo.createMessage(_message('m1', minute: 5, body: 'بخش اول'));
      await repo.createMessage(_message('m2', minute: 5, body: 'بخش دوم'));

      final threads = await repo.getAllThreads();
      expect(threads, hasLength(1));
      expect(threads.single.threadId, '09120000000');
    });

    test('getAllThreads returns one row per thread', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('a1', threadId: '09120000001'));
      await repo.createMessage(
        _message('a2', threadId: '09120000001', minute: 3),
      );
      await repo.createMessage(_message('b1', threadId: '09120000002'));

      final threads = await repo.getAllThreads();
      expect(
        threads.map((t) => t.threadId).toSet(),
        {'09120000001', '09120000002'},
      );
      expect(threads, hasLength(2));
    });

    test('getAllThreads last message is the newest one', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('m1', minute: 0, body: 'قدیمی'));
      await repo.createMessage(_message('m2', minute: 9, body: 'جدید'));

      final threads = await repo.getAllThreads();
      expect(threads.single.lastMessage, 'جدید');
    });
  });

  group('DraftRepository', () {
    test('upsert then read returns the draft', () async {
      final repo = DraftRepository();
      await repo.upsertDraft(
        Draft(id: 'd1', body: 'پیش‌نویس', updatedAt: DateTime(2026, 1, 1)),
      );

      final drafts = await repo.getDrafts();
      expect(drafts, hasLength(1));
      expect(drafts.single.body, 'پیش‌نویس');
    });

    test('upsert with the same id replaces the existing draft', () async {
      final repo = DraftRepository();
      await repo.upsertDraft(
        Draft(id: 'd1', body: 'نسخه ۱', updatedAt: DateTime(2026, 1, 1)),
      );
      await repo.upsertDraft(
        Draft(id: 'd1', body: 'نسخه ۲', updatedAt: DateTime(2026, 1, 2)),
      );

      final drafts = await repo.getDrafts();
      expect(drafts, hasLength(1));
      expect(drafts.single.body, 'نسخه ۲');
    });

    test('deleting a category leaves its drafts uncategorized', () async {
      final repo = DraftRepository();
      await repo.addCategory(
        MessageCategory(
          id: 'c1',
          name: 'تولد',
          createdAt: DateTime(2026, 1, 1),
        ),
      );
      await repo.upsertDraft(
        Draft(
          id: 'd1',
          body: 'تبریک',
          categoryId: 'c1',
          updatedAt: DateTime(2026, 1, 1),
        ),
      );

      await repo.deleteCategory('c1');

      expect(await repo.getCategories(), isEmpty);
      final uncategorized = await repo.getDrafts(uncategorized: true);
      expect(uncategorized.map((d) => d.id), ['d1']);
    });
  });

  group('CallLogRepository', () {
    test('saveCallLogsBatch persists all rows in one transaction', () async {
      final repo = CallLogRepository();
      await repo.saveCallLogsBatch([_call('1'), _call('2'), _call('3')]);

      expect(await repo.getAllCallLogs(), hasLength(3));
    });

    test(
      'getAllCallLogs returns newest first and honors limit/offset',
      () async {
        final repo = CallLogRepository();
        await repo.saveCallLogsBatch([
          _call('1', minute: 0),
          _call('2', minute: 10),
          _call('3', minute: 20),
        ]);

        final firstPage = await repo.getAllCallLogs(limit: 2, offset: 0);
        expect(firstPage.map((c) => c.id), ['3', '2']); // DESC by timestamp

        final secondPage = await repo.getAllCallLogs(limit: 2, offset: 2);
        expect(secondPage.map((c) => c.id), ['1']);
      },
    );

    test('saveCallLog replaces a row with the same id', () async {
      final repo = CallLogRepository();
      await repo.saveCallLog(_call('1'));
      await repo.saveCallLog(_call('1', minute: 30));

      final all = await repo.getAllCallLogs();
      expect(all, hasLength(1));
      expect(all.single.timestamp.minute, 30);
    });

    test('deleteCallLog removes only the targeted row', () async {
      final repo = CallLogRepository();
      await repo.saveCallLogsBatch([_call('1'), _call('2')]);

      await repo.deleteCallLog('1');

      final remaining = await repo.getAllCallLogs();
      expect(remaining.map((c) => c.id), ['2']);
    });
  });

  // NOTE: the local `contacts`-table CRUD group was removed together with the
  // dead ContactRepository CRUD itself — contacts live in the device address
  // book (flutter_contacts) and lookups resolve against the device cache.

  group('ContactRepository.filterContactsByPhoneDigits (pure)', () {
    final repo = ContactRepository();
    final contacts = [
      _contact('a', name: 'آرش', phone: '09121112233'),
      _contact('b', name: 'بهار', phone: '09354445566'),
    ];

    test('matches by a digit subsequence, ignoring formatting', () {
      final matches = repo.filterContactsByPhoneDigits(contacts, '0912 111');
      expect(matches.map((c) => c.id), ['a']);
    });

    test('returns empty for an empty / digit-less query', () {
      expect(repo.filterContactsByPhoneDigits(contacts, ''), isEmpty);
      expect(repo.filterContactsByPhoneDigits(contacts, 'abc'), isEmpty);
    });

    test('returns all contacts that contain the digits', () {
      expect(repo.filterContactsByPhoneDigits(contacts, '0').map((c) => c.id), [
        'a',
        'b',
      ]);
    });
  });

  group('ContactRepository.matchPhoneDigits (pure)', () {
    final repo = ContactRepository();
    final ali = ContactModel(
      id: 'ali',
      name: 'علی',
      phoneNumber: '09121112233',
      phoneNumbers: const ['09121112233', '09034853204'],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    test('reports the number that matched, not the contact\'s first', () {
      final matches = repo.matchPhoneDigits([ali], '09034853204');
      expect(matches, hasLength(1));
      expect(matches.single.number, '09034853204');
      expect(matches.single.contact.id, 'ali');
    });

    test('a contact matching on two numbers yields both', () {
      final matches = repo.matchPhoneDigits([ali], '090');
      expect(matches.map((m) => m.number), ['09034853204']);
      expect(repo.matchPhoneDigits([ali], '0912').map((m) => m.number), [
        '09121112233',
      ]);
      expect(repo.matchPhoneDigits([ali], '09').map((m) => m.number), [
        '09121112233',
        '09034853204',
      ]);
    });

    test('carries the offset of the typed digits for highlighting', () {
      final match = repo.matchPhoneDigits([ali], '4853').single;
      expect(match.matchStart, 4);
      expect(match.matchLength, 4);
    });

    test('empty / digit-less query matches nothing', () {
      expect(repo.matchPhoneDigits([ali], ''), isEmpty);
      expect(repo.matchPhoneDigits([ali], 'abc'), isEmpty);
    });
  });

  group('ScheduledMessageRepository', () {
    test('upsert then getAll returns the schedule', () async {
      final repo = ScheduledMessageRepository();
      await repo.upsert(_scheduled('1', at: DateTime(2026, 6, 1, 9)));

      final all = await repo.getAll();
      expect(all, hasLength(1));
      expect(all.single.id, '1');
    });

    test('getDue returns only pending rows whose time has passed', () async {
      final repo = ScheduledMessageRepository();
      final now = DateTime(2026, 6, 1, 12);
      await repo.upsert(
        _scheduled('past', at: now.subtract(const Duration(minutes: 5))),
      );
      await repo.upsert(
        _scheduled('future', at: now.add(const Duration(hours: 1))),
      );
      await repo.upsert(
        _scheduled(
          'done',
          at: now.subtract(const Duration(hours: 2)),
          status: ScheduleStatus.completed,
        ),
      );

      final due = await repo.getDue(now);
      expect(due.map((m) => m.id), ['past']);
    });

    test('getAll orders by scheduled_at ascending', () async {
      final repo = ScheduledMessageRepository();
      await repo.upsert(_scheduled('late', at: DateTime(2026, 6, 3, 9)));
      await repo.upsert(_scheduled('early', at: DateTime(2026, 6, 1, 9)));

      final all = await repo.getAll();
      expect(all.map((m) => m.id), ['early', 'late']);
    });

    test('cancel flips status to cancelled without deleting the row', () async {
      final repo = ScheduledMessageRepository();
      await repo.upsert(_scheduled('1', at: DateTime(2026, 6, 1, 9)));

      await repo.cancel('1');

      final all = await repo.getAll();
      expect(all.single.status, ScheduleStatus.cancelled);
      expect(await repo.getDue(DateTime(2026, 6, 2)), isEmpty);
    });

    test('delete removes the row', () async {
      final repo = ScheduledMessageRepository();
      await repo.upsert(_scheduled('1', at: DateTime(2026, 6, 1, 9)));

      await repo.delete('1');

      expect(await repo.getAll(), isEmpty);
    });

    test('claimDue takes ownership of due rows exactly once', () async {
      final repo = ScheduledMessageRepository();
      final now = DateTime(2026, 6, 1, 9);
      await repo.upsert(_scheduled('1', at: DateTime(2026, 6, 1, 8)));
      await repo.upsert(_scheduled('2', at: DateTime(2026, 6, 1, 8, 30)));
      await repo.upsert(_scheduled('3', at: DateTime(2026, 6, 1, 10)));

      final first = await repo.claimDue(now, 'token-a');
      expect(first.map((m) => m.id), ['1', '2']);
      expect(first.every((m) => m.status == ScheduleStatus.sending), isTrue);

      // A competing deliverer running immediately after gets nothing: the rows
      // are no longer `pending`, and the not-yet-due row is out of range.
      final second = await repo.claimDue(now, 'token-b');
      expect(second, isEmpty);
    });

    test('claimDue skips a row whose retry backoff has not elapsed', () async {
      final repo = ScheduledMessageRepository();
      final now = DateTime(2026, 6, 1, 9);
      await repo.upsert(
        _scheduled(
          '1',
          at: DateTime(2026, 6, 1, 8),
        ).withFailedAttempt(errorCode: 'NO_SERVICE', now: now),
      );

      expect(await repo.claimDue(now, 't1'), isEmpty);

      final later = now.add(ScheduledMessage.retryDelay(1));
      expect(await repo.claimDue(later, 't2'), hasLength(1));
    });

    test('releaseStaleClaims frees a row abandoned mid-send', () async {
      final repo = ScheduledMessageRepository();
      final now = DateTime(2026, 6, 1, 9);
      await repo.upsert(_scheduled('1', at: DateTime(2026, 6, 1, 8)));
      await repo.claimDue(now, 'dead-process');

      // Still owned right after the claim.
      expect(await repo.claimDue(now, 'other'), isEmpty);

      // Past the stale timeout the row is reclaimable.
      final later = now.add(
        ScheduledMessage.staleClaimTimeout + const Duration(seconds: 1),
      );
      final reclaimed = await repo.claimDue(later, 'other');
      expect(reclaimed.map((m) => m.id), ['1']);
    });

    test('earliestDueAt accounts for a pending retry backoff', () async {
      final repo = ScheduledMessageRepository();
      final now = DateTime(2026, 6, 1, 9);
      final retryAt = now.add(const Duration(minutes: 1));
      await repo.upsert(
        _scheduled(
          '1',
          at: DateTime(2026, 6, 1, 8),
        ).withFailedAttempt(errorCode: 'NO_SERVICE', now: now),
      );

      expect(await repo.earliestDueAt(), retryAt);
    });

    test('reschedule pulls the fire time forward and clears the backoff',
        () async {
      final repo = ScheduledMessageRepository();
      final now = DateTime(2026, 6, 1, 9);
      await repo.upsert(
        _scheduled(
          '1',
          at: DateTime(2026, 6, 5, 8),
        ).withFailedAttempt(errorCode: 'NO_SERVICE', now: now),
      );

      await repo.reschedule('1', now);

      final row = (await repo.getById('1'))!;
      expect(row.scheduledAt, now);
      expect(row.status, ScheduleStatus.pending);
      expect(row.attemptCount, 0);
      expect(row.nextAttemptAt, isNull);
      expect(await repo.claimDue(now, 'x'), hasLength(1));
    });
  });
}
