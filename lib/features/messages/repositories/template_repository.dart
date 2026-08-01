import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import '../models/message_template_model.dart';

/// Data access for message templates («قالب‌های آماده»).
///
/// Same shape as [DraftRepository]: pinned rows first, then most-recently
/// edited. The built-in templates are ordinary rows seeded by the schema, so
/// the user can edit or delete them like their own.
class TemplateRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<List<MessageTemplate>> getTemplates() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.messageTemplatesTable,
      orderBy: 'is_pinned DESC, updated_at DESC',
    );
    return maps.map(MessageTemplate.fromMap).toList();
  }

  Future<MessageTemplate?> getTemplate(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.messageTemplatesTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return maps.isEmpty ? null : MessageTemplate.fromMap(maps.first);
  }

  Future<void> upsertTemplate(MessageTemplate template) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.messageTemplatesTable,
      template.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Bulk delete — the multi-select bar deletes a whole selection at once.
  Future<void> deleteTemplates(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.messageTemplatesTable,
      where: 'id IN (${_placeholders(ids)})',
      whereArgs: ids,
    );
  }

  Future<void> setTemplatesPinned(List<String> ids, bool pinned) async {
    if (ids.isEmpty) return;
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messageTemplatesTable,
      {'is_pinned': pinned ? 1 : 0},
      where: 'id IN (${_placeholders(ids)})',
      whereArgs: ids,
    );
  }

  static String _placeholders(List<String> ids) =>
      List.filled(ids.length, '?').join(',');
}
