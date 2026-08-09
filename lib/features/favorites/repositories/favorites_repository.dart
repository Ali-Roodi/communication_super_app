import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import '../models/favorite_model.dart';

class FavoritesRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<List<FavoriteModel>> getFavorites() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.favoritesTable,
      orderBy: 'created_at ASC',
    );
    return maps.map(FavoriteModel.fromMap).toList();
  }

  /// Inserts a favorite. Duplicate normalized numbers are silently ignored
  /// (the table has a UNIQUE index on `normalized`).
  Future<void> addFavorite(FavoriteModel favorite) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.favoritesTable,
      favorite.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Accepts a canonical key **or** a raw number: it is normalized here, so a
  /// caller holding a display number cannot miss the row by asking with the
  /// wrong format (the same guarantee `BlockedNumbersRepository` gives).
  Future<void> removeFavorite(String normalizedOrRaw) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.favoritesTable,
      where: 'normalized = ?',
      whereArgs: [_key(normalizedOrRaw)],
    );
  }

  Future<bool> isFavorite(String normalizedOrRaw) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.favoritesTable,
      columns: ['id'],
      where: 'normalized = ?',
      whereArgs: [_key(normalizedOrRaw)],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Canonical key, falling back to the caller's string when it holds no digits
  /// (so a nonsense value simply matches nothing rather than every row).
  static String _key(String value) {
    final normalized = FavoriteModel.normalize(value);
    return normalized.isEmpty ? value : normalized;
  }
}
