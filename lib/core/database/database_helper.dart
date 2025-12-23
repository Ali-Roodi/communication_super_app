import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../constants/app_constants.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB(AppConstants.databaseName);
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: AppConstants.databaseVersion,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Contacts table
    await db.execute('''
      CREATE TABLE ${AppConstants.contactsTable} (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        email TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // Messages table
    await db.execute('''
      CREATE TABLE ${AppConstants.messagesTable} (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL,
        contact_id TEXT,
        phone_number TEXT NOT NULL,
        body TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        FOREIGN KEY (contact_id) REFERENCES ${AppConstants.contactsTable}(id)
      )
    ''');

    // Notes table
    await db.execute('''
      CREATE TABLE ${AppConstants.notesTable} (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // Call logs table (local cache)
    await db.execute('''
      CREATE TABLE ${AppConstants.callLogsTable} (
        id TEXT PRIMARY KEY,
        contact_id TEXT,
        phone_number TEXT NOT NULL,
        call_type TEXT NOT NULL,
        duration INTEGER,
        timestamp INTEGER NOT NULL,
        sim_slot INTEGER,
        FOREIGN KEY (contact_id) REFERENCES ${AppConstants.contactsTable}(id)
      )
    ''');
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}









