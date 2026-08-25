import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/favorites/models/favorite_model.dart';
import 'package:communication_super_app/features/favorites/repositories/favorites_repository.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';
import 'package:communication_super_app/features/messages/models/draft_model.dart';
import 'package:communication_super_app/features/messages/models/message_category_model.dart';
import 'package:communication_super_app/features/messages/repositories/draft_repository.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/call_history/repositories/call_log_repository.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_name_cache.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';
import 'package:communication_super_app/features/messages/repositories/scheduled_message_repository.dart';

FavoriteModel _fav(String id, String number) => FavoriteModel(
  id: id,
  phoneNumber: number,
  normalized: FavoriteModel.normalize(number),
  createdAt: DateTime(2026, 1, 1),
);

MessageModel _message(
  String id, {
  String threadId = '09120000000',
  String body = 'سلام',
  int minute = 0,
  MessageType type = MessageType.received,
  int? deviceSmsId,
  bool isRead = false,
}) => MessageModel(
  id: id,
  threadId: threadId,
  phoneNumber: threadId,
  body: body,
  type: type,
  status: MessageStatus.delivered,
  timestamp: DateTime(2026, 1, 1, 12, minute),
  deviceSmsId: deviceSmsId,
  isRead: isRead,
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

    // The column is the table's UNIQUE key, so a non-canonical key let the same
    // person be starred twice — once per number format.
    test('every equivalent form of a number is the same favourite', () async {
      final repo = FavoritesRepository();
      await repo.addFavorite(_fav('1', '+98 912 000 0000'));
      await repo.addFavorite(_fav('2', '09120000000'));
      await repo.addFavorite(_fav('3', '9120000000'));

      final all = await repo.getFavorites();
      expect(all, hasLength(1));
      expect(all.single.normalized, '09120000000');
      expect(await repo.isFavorite('+989120000000'), isTrue);
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
      await repo.block('09121112233');

      final all = await repo.getBlocked();
      expect(all, hasLength(1));
      expect(all.single.normalized, '09121112233');
    });

    test('isBlocked reflects block / unblock', () async {
      final repo = BlockedNumbersRepository();
      await repo.block('09121112233');
      expect(await repo.isBlocked('09121112233'), isTrue);

      await repo.unblock('09121112233');
      expect(await repo.isBlocked('09121112233'), isFalse);
    });

    test('favorites and blocked numbers are independent tables', () async {
      final favorites = FavoritesRepository();
      final blocked = BlockedNumbersRepository();
      await favorites.addFavorite(_fav('1', '09120000000'));
      await blocked.block('09120000000');

      expect(await favorites.getFavorites(), hasLength(1));
      expect(await blocked.getBlocked(), hasLength(1));
    });

    // The key is the canonical thread id, not "whatever digits the caller had".
    // Blocking from a conversation hands over the address as the carrier
    // delivered it; if that were stored verbatim, every lookup — which asks for
    // the national form — would miss, and blocking would silently do nothing.
    test(
      'every equivalent form of a number resolves to one blocked row',
      () async {
        final repo = BlockedNumbersRepository();
        await repo.block('+98 912 111 2233');

        final all = await repo.getBlocked();
        expect(all, hasLength(1));
        expect(all.single.normalized, '09121112233');
        expect(await repo.isBlocked('09121112233'), isTrue);
        expect(await repo.isBlocked('989121112233'), isTrue);
        expect(await repo.isBlocked('9121112233'), isTrue);

        // Blocking it again in another format must not add a second row.
        await repo.block('00989121112233');
        expect(await repo.getBlocked(), hasLength(1));
      },
    );

    test('reporting an already-blocked number upgrades it to spam', () async {
      final repo = BlockedNumbersRepository();
      await repo.block('09121112233');
      expect((await repo.getBlocked()).single.isSpam, isFalse);

      await repo.block('09121112233', report: true);
      final reported = (await repo.getBlocked()).single;
      expect(reported.isSpam, isTrue);
      expect(reported.reportedAt, isNotNull);

      // A later plain block never un-reports it.
      await repo.block('09121112233');
      expect((await repo.getBlocked()).single.isSpam, isTrue);
    });

    test('clearReport drops the report and keeps the block', () async {
      final repo = BlockedNumbersRepository();
      await repo.block('09121112233', report: true);
      await repo.clearReport('09121112233');

      final row = (await repo.getBlocked()).single;
      expect(row.isSpam, isFalse);
      expect(row.reportedAt, isNull);
      expect(await repo.isBlocked('09121112233'), isTrue);
    });

    test('blockedKeys returns every canonical key in one read', () async {
      final repo = BlockedNumbersRepository();
      await repo.block('+989121112233');
      await repo.block('0912 000 0000');

      expect(await repo.blockedKeys(), {'09121112233', '09120000000'});
    });

    test('a number with no digits is not blocked', () async {
      final repo = BlockedNumbersRepository();
      expect(await repo.block('no-digits'), isNull);
      expect(await repo.getBlocked(), isEmpty);
    });
  });

  // The reported bug: "search never finds my own messages". The old filter ran
  // over the paged-in inbox list and could only see each thread's NEWEST message,
  // which on a normal conversation is the received one.
  group('message search covers sent and received alike', () {
    test(
      'a sent body is a hit, and so is one that is not the newest message',
      () async {
        final repo = MessageRepository();
        await repo.createMessage(
          _message(
            '1',
            threadId: '09121112233',
            body: 'قرارمان سر جایش هست',
            type: MessageType.sent,
            minute: 0,
          ),
        );
        // Newer, received, and it does NOT contain the query.
        await repo.createMessage(
          _message(
            '2',
            threadId: '09121112233',
            body: 'باشه',
            type: MessageType.received,
            minute: 5,
          ),
        );

        final hits = await repo.searchMessages('قرارمان');
        expect(hits, hasLength(1));
        expect(hits.single.type, MessageType.sent);

        final threads = await repo.searchThreads('قرارمان');
        expect(threads.map((t) => t.threadId), ['09121112233']);
        // The row still shows the newest message, not the matched one.
        expect(threads.single.lastMessage, 'باشه');
      },
    );

    test('Persian folding applies to bodies, not just to names', () async {
      final repo = MessageRepository();
      await repo.createMessage(
        _message('1', body: 'علي آمد', type: MessageType.sent),
      );
      expect(await repo.searchMessages('علی'), hasLength(1));
    });

    test('a soft-deleted message is never a hit', () async {
      final repo = MessageRepository();
      await repo.createMessage(
        _message('1', body: 'یادگاری', type: MessageType.sent),
      );
      await repo.softDeleteMessages(['1']);
      expect(await repo.searchMessages('یادگاری'), isEmpty);
    });

    // The DB holds the compact template payload verbatim (see TemplateWire), so
    // the prose the user actually read is not in any column.
    test(
      'a compact template payload is searched by its rebuilt text',
      () async {
        final repo = MessageRepository();
        await repo.createMessage(
          _message('1', body: '[#T1:mtg:0]جلسه هفتگی', type: MessageType.sent),
        );
        expect(await repo.searchMessages('برقرار'), hasLength(1));
        expect(await repo.searchMessages('هفتگی'), hasLength(1));
      },
    );
  });

  // Blocking has a visible half: the conversation leaves the lists. Without it
  // the messages stop arriving but the thread sits in the inbox exactly as
  // before, which is what made blocking read as a no-op.
  group('blocked conversations leave the thread lists', () {
    test(
      'getAllThreads hides a blocked thread and unblocking brings it back',
      () async {
        final messages = MessageRepository();
        final blocked = BlockedNumbersRepository();
        await messages.createMessage(_message('1', threadId: '09121112233'));
        await messages.createMessage(_message('2', threadId: '09120000000'));

        expect(
          (await messages.getAllThreads()).map((t) => t.threadId),
          containsAll(['09121112233', '09120000000']),
        );

        // Blocked in the carrier's E.164 form — the form a conversation actually
        // hands over — while the thread id is the national one.
        await blocked.block('+989121112233', report: true);
        expect((await messages.getAllThreads()).map((t) => t.threadId), [
          '09120000000',
        ]);

        // Still readable, and reachable for the «هرزنامه و مسدودشده» page.
        expect(await messages.getMessagesByThread('09121112233'), hasLength(1));
        expect(
          (await messages.getAllThreads(
            includeBlocked: true,
          )).map((t) => t.threadId),
          containsAll(['09121112233', '09120000000']),
        );

        await blocked.unblock('09121112233');
        expect(
          (await messages.getAllThreads()).map((t) => t.threadId),
          containsAll(['09121112233', '09120000000']),
        );
      },
    );

    test('a blocked thread is hidden from search too', () async {
      final messages = MessageRepository();
      final blocked = BlockedNumbersRepository();
      await messages.createMessage(
        _message('1', threadId: '09121112233', body: 'قرار فردا'),
      );
      await blocked.block('09121112233');

      expect(await messages.searchThreads('قرار'), isEmpty);
      // The message itself is still findable — «ستاره‌دار» and the spam page
      // both read rows directly; only the thread lists filter.
      expect(await messages.searchMessages('قرار'), hasLength(1));
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

    test('softDeleteThread hides the thread but keeps the device tombstones so '
        'the mirror-sync cannot re-import it', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('m1', minute: 0, deviceSmsId: 11));
      await repo.createMessage(_message('m2', minute: 5, deviceSmsId: 12));

      await repo.softDeleteThread('09120000000');
      expect(await repo.getAllThreads(), isEmpty);

      // The provider still offers both rows (e.g. the app does not hold the
      // SMS role, so the provider delete was a no-op) — they must not come back.
      await repo.reconcileDeviceRows([
        _message('device-11', minute: 0, deviceSmsId: 11),
        _message('device-12', minute: 5, deviceSmsId: 12),
      ]);

      expect(await repo.getMessagesByThread('09120000000'), isEmpty);
      expect(await repo.getAllThreads(), isEmpty);
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
      expect(threads.map((t) => t.threadId).toSet(), {
        '09120000001',
        '09120000002',
      });
      expect(threads, hasLength(2));
    });

    test('getAllThreads last message is the newest one', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('m1', minute: 0, body: 'قدیمی'));
      await repo.createMessage(_message('m2', minute: 9, body: 'جدید'));

      final threads = await repo.getAllThreads();
      expect(threads.single.lastMessage, 'جدید');
    });

    test(
      'getAllThreads floats a pinned thread above a newer unpinned one',
      () async {
        final repo = MessageRepository();
        await repo.createMessage(_message('a1', threadId: '09120000001'));
        await repo.createMessage(
          _message('b1', threadId: '09120000002', minute: 30),
        );

        await repo.pinThread('09120000001');

        final threads = await repo.getAllThreads();
        expect(threads.map((t) => t.threadId), ['09120000001', '09120000002']);
        expect(threads.first.isPinned, isTrue);
        expect(threads.last.isPinned, isFalse);
      },
    );

    test('getAllThreads paging applies to threads, not to messages', () async {
      final repo = MessageRepository();
      // Three threads, several messages each: a page of 2 must still return
      // two *threads* (the paging happens before the per-thread work).
      for (var t = 1; t <= 3; t++) {
        for (var m = 0; m < 3; m++) {
          await repo.createMessage(
            _message(
              't$t-m$m',
              threadId: '0912000000$t',
              minute: t * 10 + m,
              body: 'پیام $t-$m',
            ),
          );
        }
      }

      final firstPage = await repo.getAllThreads(limit: 2, offset: 0);
      final secondPage = await repo.getAllThreads(limit: 2, offset: 2);

      expect(firstPage.map((t) => t.threadId), ['09120000003', '09120000002']);
      expect(secondPage.map((t) => t.threadId), ['09120000001']);
      expect(firstPage.first.lastMessage, 'پیام 3-2');
    });

    test('getAllThreads counts only unread received messages', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('r1', minute: 0, isRead: false));
      await repo.createMessage(
        _message('r2', minute: 1, body: 'دومی', isRead: false),
      );
      await repo.createMessage(
        _message('r3', minute: 2, body: 'خوانده', isRead: true),
      );

      expect((await repo.getAllThreads()).single.unreadCount, 2);
    });

    test(
      'markThreadAsUnread marks a thread whose messages are all sent',
      () async {
        final repo = MessageRepository();
        await repo.createMessage(
          _message('s1', minute: 0, type: MessageType.sent, isRead: true),
        );
        await repo.createMessage(
          _message(
            's2',
            minute: 1,
            body: 'دومی',
            type: MessageType.sent,
            isRead: true,
          ),
        );

        await repo.markThreadAsUnread('09120000000');

        // Exactly one row flagged — the newest — so the badge reads «۱».
        expect((await repo.getAllThreads()).single.unreadCount, 1);

        await repo.markThreadAsRead('09120000000');
        expect((await repo.getAllThreads()).single.unreadCount, 0);
      },
    );

    test('markThreadAsUnread ignores deleted received messages', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('r1', minute: 0, isRead: true));
      await repo.createMessage(
        _message(
          's1',
          minute: 1,
          body: 'پاسخ',
          type: MessageType.sent,
          isRead: true,
        ),
      );
      await repo.softDeleteMessages(['r1']);

      await repo.markThreadAsUnread('09120000000');

      expect((await repo.getAllThreads()).single.unreadCount, 1);
    });

    test('removeRowsMissingFromDevice drops rows whose provider id vanished '
        'and keeps provider-less ones', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('m1', minute: 0, deviceSmsId: 11));
      await repo.createMessage(
        _message('m2', minute: 1, body: 'دوم', deviceSmsId: 12),
      );
      // No device_sms_id: sent while the app wasn't the default SMS app.
      await repo.createMessage(_message('m3', minute: 2, body: 'سوم'));

      // The device still has 11 — 12 was deleted there.
      final removed = await repo.removeRowsMissingFromDevice({11});

      expect(removed, 1);
      final remaining = await repo.getMessagesByThread('09120000000');
      expect(remaining.map((m) => m.id), ['m1', 'm3']);
    });

    test(
      'removeRowsMissingFromDevice is a no-op when every id is still there',
      () async {
        final repo = MessageRepository();
        await repo.createMessage(_message('m1', minute: 0, deviceSmsId: 11));
        await repo.createMessage(
          _message('m2', minute: 1, body: 'دوم', deviceSmsId: 12),
        );

        expect(await repo.removeRowsMissingFromDevice({11, 12}), 0);
        expect(await repo.getMessagesByThread('09120000000'), hasLength(2));
      },
    );
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

    test(
      'deleteCategories moves every affected draft to uncategorized',
      () async {
        final repo = DraftRepository();
        for (final id in ['c1', 'c2']) {
          await repo.addCategory(
            MessageCategory(
              id: id,
              name: 'دسته $id',
              createdAt: DateTime(2026, 1, 1),
            ),
          );
        }
        await repo.upsertDraft(
          Draft(
            id: 'd1',
            body: 'یک',
            categoryId: 'c1',
            updatedAt: DateTime(2026, 1, 1),
          ),
        );
        await repo.upsertDraft(
          Draft(
            id: 'd2',
            body: 'دو',
            categoryId: 'c2',
            updatedAt: DateTime(2026, 1, 2),
          ),
        );

        await repo.deleteCategories(['c1', 'c2']);

        expect(await repo.getCategories(), isEmpty);
        expect(
          (await repo.getDrafts(uncategorized: true)).map((d) => d.id).toSet(),
          {'d1', 'd2'},
        );
      },
    );

    test('pinned drafts sort above newer unpinned ones', () async {
      final repo = DraftRepository();
      await repo.upsertDraft(
        Draft(id: 'old', body: 'قدیمی', updatedAt: DateTime(2026, 1, 1)),
      );
      await repo.upsertDraft(
        Draft(id: 'new', body: 'جدید', updatedAt: DateTime(2026, 1, 9)),
      );

      await repo.setDraftsPinned(['old'], true);

      expect((await repo.getDrafts()).map((d) => d.id), ['old', 'new']);
      expect((await repo.getDrafts()).first.isPinned, isTrue);

      await repo.setDraftsPinned(['old'], false);
      expect((await repo.getDrafts()).map((d) => d.id), ['new', 'old']);
    });

    test('pinned categories sort above the name ordering', () async {
      final repo = DraftRepository();
      await repo.addCategory(
        MessageCategory(id: 'a', name: 'الف', createdAt: DateTime(2026, 1, 1)),
      );
      await repo.addCategory(
        MessageCategory(id: 'b', name: 'ب', createdAt: DateTime(2026, 1, 1)),
      );

      await repo.setCategoriesPinned(['b'], true);

      expect((await repo.getCategories()).map((c) => c.id), ['b', 'a']);
    });

    test(
      'moveDraftsToCategory files a selection without touching updated_at',
      () async {
        final repo = DraftRepository();
        final stamp = DateTime(2026, 1, 1);
        await repo.addCategory(
          MessageCategory(id: 'c1', name: 'تولد', createdAt: stamp),
        );
        await repo.upsertDraft(Draft(id: 'd1', body: 'یک', updatedAt: stamp));
        await repo.upsertDraft(Draft(id: 'd2', body: 'دو', updatedAt: stamp));

        await repo.moveDraftsToCategory(['d1', 'd2'], 'c1');

        final filed = await repo.getDrafts(categoryId: 'c1');
        expect(filed.map((d) => d.id).toSet(), {'d1', 'd2'});
        expect(filed.every((d) => d.updatedAt == stamp), isTrue);
        expect(await repo.getDrafts(uncategorized: true), isEmpty);

        // …and back out again.
        await repo.moveDraftsToCategory(['d1'], null);
        expect((await repo.getDrafts(uncategorized: true)).map((d) => d.id), [
          'd1',
        ]);
      },
    );

    test('deleteDrafts removes the whole selection', () async {
      final repo = DraftRepository();
      for (final id in ['d1', 'd2', 'd3']) {
        await repo.upsertDraft(
          Draft(id: id, body: id, updatedAt: DateTime(2026, 1, 1)),
        );
      }

      await repo.deleteDrafts(['d1', 'd3']);

      expect((await repo.getDrafts()).map((d) => d.id), ['d2']);
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

    test(
      'reschedule pulls the fire time forward and clears the backoff',
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
      },
    );
  });

  group('ContactNameCache', () {
    setUp(ContactNameCache.resetForTest);

    test('round-trips the address book, keyed on the canonical number', () async {
      await ContactNameCache.write([
        _contact('1', name: 'ایمان', phone: '+98 910 790 2209'),
      ]);
      ContactNameCache.resetForTest();

      final read = await ContactNameCache.read();
      // Written as E.164 with spaces, found by the national form — the same key
      // `messages.thread_id` and `blocked_numbers.normalized` use.
      expect(read['09107902209']?.name, 'ایمان');
      expect(read['09107902209']?.contactId, '1');
    });

    test('a contact that left the address book leaves the cache', () async {
      await ContactNameCache.write([
        _contact('1', name: 'ایمان', phone: '09107902209'),
        _contact('2', name: 'مریم', phone: '09121111111'),
      ]);
      // The whole set is replaced, not upserted — an upsert-only cache would go
      // on naming a contact the user deleted.
      await ContactNameCache.write([
        _contact('2', name: 'مریم', phone: '09121111111'),
      ]);
      ContactNameCache.resetForTest();

      final read = await ContactNameCache.read();
      expect(read.containsKey('09107902209'), isFalse);
      expect(read['09121111111']?.name, 'مریم');
    });

    test('an unchanged address book is not rewritten', () async {
      final contacts = [_contact('1', name: 'ایمان', phone: '09107902209')];
      await ContactNameCache.write(contacts);
      // Second write is a no-op; the point is that it neither throws nor loses
      // the row (this is what runs after every cached contacts read).
      await ContactNameCache.write(contacts);
      ContactNameCache.resetForTest();

      expect((await ContactNameCache.read()), hasLength(1));
    });
  });
}
