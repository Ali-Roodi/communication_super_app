import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../constants/app_constants.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    try {
      _database = await _initDB(AppConstants.databaseName);
      return _database!;
    } catch (e) {
      throw Exception('Failed to initialize database: $e');
    }
  }

  Future<Database> _initDB(String filePath) async {
    try {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, filePath);

      return await openDatabase(
        path,
        version: AppConstants.databaseVersion,
        onCreate: _createDB,
        onUpgrade: _onUpgrade,
      );
    } catch (e) {
      throw Exception('Failed to open database: $e');
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Migration from version 1 to 2: Add is_read field to messages table
    if (oldVersion < 2) {
      await db.execute('''
        ALTER TABLE ${AppConstants.messagesTable} 
        ADD COLUMN is_read INTEGER DEFAULT 0
      ''');
      
      // Mark all sent messages as read by default
      await db.execute('''
        UPDATE ${AppConstants.messagesTable} 
        SET is_read = 1 
        WHERE type = 'sent'
      ''');
      
      // Create index for faster unread queries
      await db.execute('''
        CREATE INDEX idx_messages_is_read ON ${AppConstants.messagesTable}(is_read)
      ''');
    }

    // Migration from version 2 to 3:
    // Add a unique content index to prevent duplicate rows that arise when a
    // message is first inserted by the live BroadcastReceiver and then
    // re-imported from the device inbox (which assigns a different id).
    if (oldVersion < 3) {
      // Remove any pre-existing duplicates, keeping the row with the smallest
      // rowid (the first-inserted, i.e. the live-received UUID row).
      await db.execute('''
        DELETE FROM ${AppConstants.messagesTable}
        WHERE rowid NOT IN (
          SELECT MIN(rowid)
          FROM ${AppConstants.messagesTable}
          GROUP BY phone_number, body, timestamp, type
        )
      ''');

      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_content_unique
        ON ${AppConstants.messagesTable}(phone_number, body, timestamp, type)
      ''');
    }
  }

  Future<void> _createDB(Database db, int version) async {
    try {
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
          is_read INTEGER DEFAULT 0,
          FOREIGN KEY (contact_id) REFERENCES ${AppConstants.contactsTable}(id) ON DELETE SET NULL
        )
      ''');

      // Create index for faster thread queries
      await db.execute('''
        CREATE INDEX idx_messages_thread_id ON ${AppConstants.messagesTable}(thread_id)
      ''');

      // Create index for faster timestamp sorting
      await db.execute('''
        CREATE INDEX idx_messages_timestamp ON ${AppConstants.messagesTable}(timestamp DESC)
      ''');

      // Create index for faster unread queries
      await db.execute('''
        CREATE INDEX idx_messages_is_read ON ${AppConstants.messagesTable}(is_read)
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
          FOREIGN KEY (contact_id) REFERENCES ${AppConstants.contactsTable}(id) ON DELETE SET NULL
        )
      ''');

      // Create index for faster call log queries
      await db.execute('''
        CREATE INDEX idx_call_logs_timestamp ON ${AppConstants.callLogsTable}(timestamp DESC)
      ''');
    } catch (e) {
      throw Exception('Failed to create database tables: $e');
    }
  }

  Future<void> close() async {
    try {
      final db = await database;
      await db.close();
      _database = null;
    } catch (e) {
      throw Exception('Failed to close database: $e');
    }
  }
}










