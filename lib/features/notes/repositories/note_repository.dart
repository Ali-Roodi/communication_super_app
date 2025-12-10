import 'package:sqflite/sqflite.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import '../models/note_model.dart';

class NoteRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<List<NoteModel>> getAllNotes() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.notesTable,
      orderBy: 'updated_at DESC',
    );
    return maps.map((map) => NoteModel.fromMap(map)).toList();
  }

  Future<NoteModel?> getNoteById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.notesTable,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return NoteModel.fromMap(maps.first);
  }

  Future<String> createNote(NoteModel note) async {
    final db = await _dbHelper.database;
    await db.insert(
      AppConstants.notesTable,
      note.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return note.id;
  }

  Future<void> updateNote(NoteModel note) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.notesTable,
      note.copyWith(updatedAt: DateTime.now()).toMap(),
      where: 'id = ?',
      whereArgs: [note.id],
    );
  }

  Future<void> deleteNote(String id) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.notesTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<NoteModel>> searchNotes(String query) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      AppConstants.notesTable,
      where: 'title LIKE ? OR content LIKE ?',
      whereArgs: ['%$query%', '%$query%'],
      orderBy: 'updated_at DESC',
    );
    return maps.map((map) => NoteModel.fromMap(map)).toList();
  }
}


