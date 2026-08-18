import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/models/message_search_query.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';

MessageModel _message(
  String id, {
  String threadId = '09120000000',
  required String body,
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
  isRead: true,
);

/// Drains the index the way `MessageBloc._drainSearchIndex` does.
Future<void> _drain(MessageRepository repo) async {
  while (await repo.syncSearchIndex() > 0) {}
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
  });

  setUp(() => DatabaseHelper.resetForTesting());
  tearDownAll(() => DatabaseHelper.resetForTesting());

  group('MessageSearchQuery.tight / canUseFts', () {
    test(
      'folds and strips spacing, and refuses a needle under three chars',
      () {
        expect(MessageSearchQuery('محمد رضا').tight, 'محمدرضا');
        // ي → ی, Persian digits → ASCII, spacing gone.
        expect(MessageSearchQuery('علي ۵').tight, 'علی5');
        expect(MessageSearchQuery('جلسه').canUseFts, isTrue);
        expect(MessageSearchQuery('اب').canUseFts, isFalse);
        expect(MessageSearchQuery('a').canUseFts, isFalse);
      },
    );

    test('quotes the MATCH argument and doubles embedded quotes', () {
      expect(MessageSearchQuery('جلسه').ftsMatch, '"جلسه"');
      expect(MessageSearchQuery('a"b c').ftsMatch, '"a""bc"');
    });
  });

  group('search index', () {
    test(
      'a fresh database indexes what it is given and reports ready',
      () async {
        final repo = MessageRepository();
        await repo.createMessage(_message('1', body: 'جلسه هفتگی ساعت ۱۰'));

        // Nothing indexed yet, so the index must NOT be trusted — a half-filled
        // index that answered here would silently omit this very message.
        expect(await repo.searchIndexReady(), isFalse);
        // …and the search still finds it, through the scan path.
        expect(await repo.searchMessages('هفتگی'), hasLength(1));

        await _drain(repo);
        if (!DatabaseHelper.messageSearchFtsReady) return; // no FTS5 here
        expect(await repo.searchIndexReady(), isTrue);
        expect(await repo.searchMessages('هفتگی'), hasLength(1));
      },
    );

    test('both paths answer identically', () async {
      final repo = MessageRepository();
      final bodies = <String, String>{
        '1': 'جلسه هفتگی در مورخه ۱۴۰۵/۰۵/۲۰ برقرار می‌باشد',
        '2': 'محمد رضا تماس گرفت',
        '3': 'علي آمد',
        '4': 'قرار فردا ساعت ۹ صبح',
        '5': 'Meeting moved to Monday',
      };
      var minute = 0;
      for (final entry in bodies.entries) {
        await repo.createMessage(
          _message(entry.key, body: entry.value, minute: minute++),
        );
      }

      const queries = [
        'جلسه',
        'هفتگی',
        'محمدرضا', // spacing-optional
        'محمد رضا',
        'علی', // folded ي → ی
        'ساعت',
        'monday',
        'MEETING',
        '۱۴۰۵',
        '1405',
        'نیست‌جایی',
      ];

      // Scan path first (index empty ⇒ not ready).
      final viaScan = <String, List<String>>{};
      for (final q in queries) {
        viaScan[q] = [for (final m in await repo.searchMessages(q)) m.id];
      }

      await _drain(repo);
      if (!DatabaseHelper.messageSearchFtsReady) return;
      expect(await repo.searchIndexReady(), isTrue);

      for (final q in queries) {
        final viaFts = [for (final m in await repo.searchMessages(q)) m.id];
        expect(viaFts, viaScan[q], reason: 'query «$q»');
      }
    });

    test('a template payload is indexed by its rebuilt prose', () async {
      final repo = MessageRepository();
      await repo.createMessage(
        _message('1', body: '[#T1:mtg:0]جلسه هفتگی', type: MessageType.sent),
      );
      await _drain(repo);
      if (!DatabaseHelper.messageSearchFtsReady) return;

      expect(await repo.searchIndexReady(), isTrue);
      // «برقرار» exists only in the template's compiled-in prose, never in the
      // stored column.
      expect(await repo.searchMessages('برقرار'), hasLength(1));
      expect(await repo.searchMessages('هفتگی'), hasLength(1));
    });

    test('a new message re-opens the backlog until it is folded in', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('1', body: 'اولی'));
      await _drain(repo);
      if (!DatabaseHelper.messageSearchFtsReady) return;
      expect(await repo.searchIndexReady(), isTrue);

      // Anything that inserts without folding — the native scheduled worker, the
      // notification quick-reply — leaves search_indexed = 0.
      await repo.createMessage(_message('2', body: 'دومی', minute: 5));
      expect(await repo.searchIndexReady(), isFalse);
      // Still found, via the scan.
      expect(await repo.searchMessages('دومی'), hasLength(1));

      await _drain(repo);
      expect(await repo.searchIndexReady(), isTrue);
      expect(await repo.searchMessages('دومی'), hasLength(1));
    });

    test('a soft-deleted message is not a hit on the indexed path', () async {
      final repo = MessageRepository();
      await repo.createMessage(_message('1', body: 'یادگاری'));
      await _drain(repo);
      if (!DatabaseHelper.messageSearchFtsReady) return;

      await repo.softDeleteMessages(['1']);
      // The tombstone keeps its index entry (the row is still there, flagged);
      // the join's `is_deleted = 0` is what must exclude it.
      expect(await repo.searchMessages('یادگاری'), isEmpty);
    });

    test('threads are found through the index too', () async {
      final repo = MessageRepository();
      await repo.createMessage(
        _message(
          '1',
          threadId: '09121112233',
          body: 'قرارمان سر جایش هست',
          type: MessageType.sent,
        ),
      );
      await repo.createMessage(
        _message('2', threadId: '09121112233', body: 'باشه', minute: 5),
      );
      await _drain(repo);
      if (!DatabaseHelper.messageSearchFtsReady) return;

      final threads = await repo.searchThreads('قرارمان');
      expect(threads.map((t) => t.threadId), ['09121112233']);
      expect(threads.single.lastMessage, 'باشه');
    });
  });
}
