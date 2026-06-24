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
}
