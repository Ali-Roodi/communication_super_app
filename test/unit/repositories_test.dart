import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/favorites/models/favorite_model.dart';
import 'package:communication_super_app/features/favorites/repositories/favorites_repository.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';

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
}
