import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../constants/app_constants.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  /// When set, the database is opened at this exact path instead of the default
  /// app location. Tests point it at an in-memory database.
  @visibleForTesting
  static String? databasePathOverride;

  /// Closes and clears the cached handle so the next access re-opens a fresh
  /// database. Used between tests for isolation.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    await _database?.close();
    _database = null;
  }

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
      final path =
          databasePathOverride ?? join(await getDatabasesPath(), filePath);

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

    // Migration from version 3 to 4: add the favorites table.
    // Favorites are keyed by normalized phone number (digits only) rather than
    // a contacts-table id, because the app's contacts are read from the device
    // (flutter_contacts), not stored as rows in the contacts table.
    if (oldVersion < 4) {
      await _createFavoritesTable(db);
    }

    // Migration from version 4 to 5: add the blocked_numbers table.
    if (oldVersion < 5) {
      await _createBlockedNumbersTable(db);
    }

    // Migration from version 5 to 6:
    // - archived_threads / pinned_threads: per-thread state for the Google
    //   Messages style archive & pin features. Keyed by thread_id (the
    //   digits-only normalized phone number, same as messages.thread_id).
    // - messages.is_deleted: soft-delete flag so a deleted message can be
    //   hidden from the UI without losing the dedup unique-index row.
    // - contacts.is_favorite / contacts.ringtone_uri: per-contact metadata for
    //   the favorites star and assigned-ringtone features.
    if (oldVersion < 6) {
      await _createArchivedThreadsTable(db);
      await _createPinnedThreadsTable(db);
      await db.execute('''
        ALTER TABLE ${AppConstants.messagesTable}
        ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0
      ''');
      await db.execute('''
        ALTER TABLE ${AppConstants.contactsTable}
        ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0
      ''');
      await db.execute('''
        ALTER TABLE ${AppConstants.contactsTable}
        ADD COLUMN ringtone_uri TEXT
      ''');
    }

    // Migration from version 6 to 7:
    // - message_categories: user-defined labels for drafts (e.g. "تولد").
    // - drafts: saved message drafts with an optional title (not sent) and an
    //   optional category. category_id → message_categories ON DELETE SET NULL
    //   so deleting a category leaves its drafts in "بدون دسته‌بندی".
    if (oldVersion < 7) {
      await _createMessageCategoriesTable(db);
      await _createDraftsTable(db);
    }

    // Migration from version 7 to 8:
    // - scheduled_messages: queued outgoing SMS with an optional recurrence and
    //   end condition. `scheduled_at` is the next nominal fire time (the column
    //   the "due" query filters on); recurrence advances it after each send.
    if (oldVersion < 8) {
      await _createScheduledMessagesTable(db);
    }

    // Migration from version 8 to 9: drop the unused `notes` table (the notes
    // feature was never built).
    if (oldVersion < 9) {
      await db.execute('DROP TABLE IF EXISTS notes');
    }

    // Migration from version 9 to 10: make scheduled-message delivery safe when
    // the foreground (Dart) and background (native AlarmManager) deliverers race.
    //
    // - claim_token / claimed_at: a due row is *claimed* with a random token in
    //   one atomic UPDATE before it is sent, so exactly one deliverer owns it.
    //   A claim older than the stale timeout is reclaimed (process died mid-send).
    // - attempt_count / next_attempt_at / last_error: a transient send failure
    //   (no service, no SIM) now backs off and retries instead of permanently
    //   marking the schedule failed.
    if (oldVersion < 10) {
      await _addScheduledDeliveryColumns(db);
    }

    // Migration from version 10 to 11: messages.device_sms_id — the row id of
    // this message inside the device SMS provider (content://sms). Written by
    // the mirror-sync and by the sent write-through; used so an in-app delete
    // can remove the exact provider row (global delete) instead of relying on
    // content matching.
    if (oldVersion < 11) {
      await db.execute('''
        ALTER TABLE ${AppConstants.messagesTable}
        ADD COLUMN device_sms_id INTEGER
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_messages_device_sms_id
        ON ${AppConstants.messagesTable}(device_sms_id)
      ''');
    }
  }

  /// v10 columns on `scheduled_messages`. Split out so `_createDB` and the
  /// migration can't drift apart.
  Future<void> _addScheduledDeliveryColumns(Database db) async {
    const table = AppConstants.scheduledMessagesTable;
    await db.execute(
      'ALTER TABLE $table ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute('ALTER TABLE $table ADD COLUMN next_attempt_at INTEGER');
    await db.execute('ALTER TABLE $table ADD COLUMN last_error TEXT');
    await db.execute('ALTER TABLE $table ADD COLUMN claim_token TEXT');
    await db.execute('ALTER TABLE $table ADD COLUMN claimed_at INTEGER');
  }

  Future<void> _createFavoritesTable(Database db) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.favoritesTable} (
        id TEXT PRIMARY KEY,
        phone_number TEXT NOT NULL,
        normalized TEXT NOT NULL UNIQUE,
        name TEXT,
        contact_id TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createBlockedNumbersTable(Database db) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.blockedNumbersTable} (
        id TEXT PRIMARY KEY,
        phone_number TEXT NOT NULL,
        normalized TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createArchivedThreadsTable(Database db) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.archivedThreadsTable} (
        thread_id TEXT PRIMARY KEY,
        archived_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createPinnedThreadsTable(Database db) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.pinnedThreadsTable} (
        thread_id TEXT PRIMARY KEY,
        pinned_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createMessageCategoriesTable(Database db) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.messageCategoriesTable} (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createDraftsTable(Database db) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.draftsTable} (
        id TEXT PRIMARY KEY,
        title TEXT,
        body TEXT NOT NULL,
        category_id TEXT,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (category_id) REFERENCES ${AppConstants.messageCategoriesTable}(id) ON DELETE SET NULL
      )
    ''');
  }

  Future<void> _createScheduledMessagesTable(Database db) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.scheduledMessagesTable} (
        id TEXT PRIMARY KEY,
        phone_number TEXT NOT NULL,
        contact_name TEXT,
        body TEXT NOT NULL,
        scheduled_at INTEGER NOT NULL,
        repeat TEXT NOT NULL DEFAULT 'none',
        repeat_every INTEGER NOT NULL DEFAULT 1,
        weekdays TEXT,
        jitter TEXT NOT NULL DEFAULT 'none',
        end_type TEXT NOT NULL DEFAULT 'never',
        end_date INTEGER,
        max_occurrences INTEGER,
        occurrence_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER,
        last_error TEXT,
        claim_token TEXT,
        claimed_at INTEGER
      )
    ''');
    // The delivery worker filters on (status, scheduled_at); index it.
    await db.execute('''
      CREATE INDEX idx_scheduled_due
      ON ${AppConstants.scheduledMessagesTable}(status, scheduled_at)
    ''');
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
          is_favorite INTEGER NOT NULL DEFAULT 0,
          ringtone_uri TEXT,
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
          is_deleted INTEGER NOT NULL DEFAULT 0,
          device_sms_id INTEGER,
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

      // Unique content index — keeps fresh installs in sync with databases
      // upgraded through the v2→v3 migration. Prevents duplicate rows when a
      // message is first inserted by the live receiver and then re-imported
      // from the device inbox (different id, same content). All batch inserts
      // rely on this with ConflictAlgorithm.ignore.
      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_content_unique
        ON ${AppConstants.messagesTable}(phone_number, body, timestamp, type)
      ''');

      // Provider row-id lookup (mirror-sync + global delete)
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_messages_device_sms_id
        ON ${AppConstants.messagesTable}(device_sms_id)
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

      // Favorites table (starred phone numbers)
      await _createFavoritesTable(db);

      // Blocked numbers table
      await _createBlockedNumbersTable(db);

      // Archived & pinned thread state (Google Messages style)
      await _createArchivedThreadsTable(db);
      await _createPinnedThreadsTable(db);

      // Message categories + drafts (Messages "pro" suite)
      await _createMessageCategoriesTable(db);
      await _createDraftsTable(db);

      // Scheduled outgoing messages
      await _createScheduledMessagesTable(db);
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
