import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import '../models/draft_model.dart';
import '../models/message_category_model.dart';

/// Data access for drafts (پیش‌نویس‌ها) and their categories (دسته‌بندی‌ها).
class DraftRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  // ── Drafts ────────────────────────────────────────────────────────────────

  /// All drafts, newest first. When [categoryId] is provided, only drafts in
  /// that category are returned. Pass [uncategorized] = true for drafts with no
  /// category («بدون دسته‌بندی»).
  Future<List<Draft>> getDrafts({
    String? categoryId,
    bool uncategorized = false,
  }) async {
    final db = await _dbHelper.database;
    String? where;
    List<Object?>? args;
    if (uncategorized) {
      where = 'category_id IS NULL';
    } else if (categoryId != null) {
      where = 'category_id = ?';
      args = [categoryId];
    }
    final maps = await db.query(
      AppConstants.draftsTable,
      where: where,
      whereArgs: args,
      orderBy: 'updated_at DESC',
    );
    return maps.map(Draft.fromMap).toList();
  }

  Future<void> upsertDraft(Draft draft) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.draftsTable,
      draft.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteDraft(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.draftsTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── Categories ──────────────────────────────────────────────────────────--

  /// All categories ordered by name, each with its [MessageCategory.draftCount].
  Future<List<MessageCategory>> getCategories() async {
    final db = await _dbHelper.database;
    final maps = await db.rawQuery('''
      SELECT c.*, COUNT(d.id) AS draft_count
      FROM ${AppConstants.messageCategoriesTable} c
      LEFT JOIN ${AppConstants.draftsTable} d ON d.category_id = c.id
      GROUP BY c.id
      ORDER BY c.name ASC
    ''');
    return maps.map(MessageCategory.fromMap).toList();
  }

  /// Total draft count and uncategorized count, for the «همه» / «بدون دسته‌بندی»
  /// virtual rows on the categories screen.
  Future<({int total, int uncategorized})> getDraftCounts() async {
    final db = await _dbHelper.database;
    final totalRows = await db
        .rawQuery('SELECT COUNT(*) AS c FROM ${AppConstants.draftsTable}');
    final uncatRows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${AppConstants.draftsTable} WHERE category_id IS NULL');
    final total = Sqflite.firstIntValue(totalRows) ?? 0;
    final uncategorized = Sqflite.firstIntValue(uncatRows) ?? 0;
    return (total: total, uncategorized: uncategorized);
  }

  Future<void> addCategory(MessageCategory category) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.messageCategoriesTable,
      category.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> renameCategory(String id, String name) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messageCategoriesTable,
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Deletes the category and moves its drafts to «بدون دسته‌بندی». The drafts
  /// are nulled explicitly because sqflite does not enable FK enforcement
  /// (so the ON DELETE SET NULL constraint would not fire on its own).
  Future<void> deleteCategory(String id) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      await txn.update(
        AppConstants.draftsTable,
        {'category_id': null},
        where: 'category_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        AppConstants.messageCategoriesTable,
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }
}
