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

  Future<void> removeFavorite(String normalized) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.favoritesTable,
      where: 'normalized = ?',
      whereArgs: [normalized],
    );
  }

  Future<bool> isFavorite(String normalized) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.favoritesTable,
      columns: ['id'],
      where: 'normalized = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
