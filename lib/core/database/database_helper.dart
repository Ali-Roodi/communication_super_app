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

    // Migration from version 11 to 12: composite indexes for the inbox query.
    // getAllThreads runs two correlated subqueries per thread (unread count +
    // newest-row picker); on a mailbox with tens of thousands of messages the
    // single-column thread_id index forces wide scans. These cover both.
    if (oldVersion < 12) {
      await _createThreadQueryIndexes(db);
    }

    // Migration from version 12 to 13: messages.is_starred — «ستاره‌دار», the
    // per-message bookmark Google Messages keeps. Purely local metadata: the
    // mirror-sync inserts with ConflictAlgorithm.ignore, so it never clears it.
    if (oldVersion < 13) {
      await db.execute('''
        ALTER TABLE ${AppConstants.messagesTable}
        ADD COLUMN is_starred INTEGER DEFAULT 0
      ''');
      await _createStarredIndex(db);
    }

    // v14: drafts and their categories can be pinned to the top of their list.
    if (oldVersion < 14) {
      await db.execute('''
        ALTER TABLE ${AppConstants.draftsTable}
        ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0
      ''');
      await db.execute('''
        ALTER TABLE ${AppConstants.messageCategoriesTable}
        ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0
      ''');
    }

    // v15: message_templates — reusable message bodies with `[...]` placeholders
    // («قالب آماده»). Seeded with the built-in templates, which are ordinary
    // rows from then on: the user may edit, pin or delete them.
    if (oldVersion < 15) {
      await _createMessageTemplatesTable(db);
      await _seedMessageTemplates(db);
    }
  }

  /// v13 index backing the «ستاره‌دار» screen.
  Future<void> _createStarredIndex(Database db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_is_starred
      ON ${AppConstants.messagesTable}(is_starred, timestamp DESC)
    ''');
  }

  /// v12 composite indexes (also created on fresh installs in `_createDB`).
  Future<void> _createThreadQueryIndexes(Database db) async {
    // Unread-count subquery: thread_id + type + is_read + is_deleted.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_thread_unread
      ON ${AppConstants.messagesTable}(thread_id, type, is_read, is_deleted)
    ''');
    // Newest-row picker: per-thread ORDER BY timestamp DESC, rowid DESC.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_thread_ts
      ON ${AppConstants.messagesTable}(thread_id, timestamp DESC)
    ''');
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
        created_at INTEGER NOT NULL,
        is_pinned INTEGER NOT NULL DEFAULT 0
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
        is_pinned INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (category_id) REFERENCES ${AppConstants.messageCategoriesTable}(id) ON DELETE SET NULL
      )
    ''');
  }

  Future<void> _createMessageTemplatesTable(Database db) async {
    await db.execute('''
      CREATE TABLE ${AppConstants.messageTemplatesTable} (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        use_contact_name INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )
    ''');
    // The board reads the whole table in one sorted query.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_templates_sort
      ON ${AppConstants.messageTemplatesTable}(is_pinned DESC, updated_at DESC)
    ''');
  }

  /// The templates the app ships with. Ids are fixed strings so the seed is
  /// idempotent (INSERT OR IGNORE) even if it ever runs twice; everything else
  /// about them is user-editable from «قالب‌های آماده».
  ///
  /// `[...]` names drive the generated form — see `TemplateEngine`. A «تاریخ» +
  /// «زمان» pair is asked for with one picker, so writing both here is what
  /// produces the Figma «تاریخ و زمان» row.
  Future<void> _seedMessageTemplates(Database db) async {
    const seeds = <(String, String, String, int)>[
      (
        'tpl-meeting',
        'دعوت‌نامه جلسه',
        'جلسه [عنوان] در مورخه [تاریخ] ساعت [زمان] در محل [مکان] برقرار می‌باشد.\n[توضیحات]',
        1,
      ),
      (
        'tpl-reminder',
        'یادآوری قرار',
        'یادآوری می‌شود [عنوان] در مورخه [تاریخ] ساعت [زمان] برگزار می‌شود.',
        1,
      ),
      (
        'tpl-payment',
        'اطلاع واریز',
        'مبلغ [مبلغ] تومان بابت [بابت] در تاریخ [تاریخ] واریز شد.\n[توضیحات]',
        1,
      ),
      (
        'tpl-congrats',
        'تبریک',
        '[مناسبت] را صمیمانه به شما تبریک می‌گویم.',
        1,
      ),
      (
        'tpl-thanks',
        'تشکر',
        'با سلام، از پیگیری و همراهی شما سپاسگزارم.',
        0,
      ),
      (
        'tpl-followup',
        'پیگیری',
        'با سلام، جهت پیگیری موضوع مطرح‌شده مزاحم شدم. ممنون می‌شوم در صورت امکان پاسخ بفرمایید.',
        0,
      ),
      (
        'tpl-call',
        'هماهنگی تماس',
        'با سلام، چه زمانی برای یک تماس کوتاه در دسترس هستید؟',
        0,
      ),
      (
        'tpl-apology',
        'عذرخواهی بابت تأخیر',
        'با سلام، بابت تأخیر پیش‌آمده پوزش می‌خواهم. [توضیحات]',
        0,
      ),
    ];

    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    // Seeded newest-first in list order: each row is stamped a millisecond
    // older than the one before, so the board opens in the order written here.
    for (var i = 0; i < seeds.length; i++) {
      final (id, title, body, useName) = seeds[i];
      batch.insert(AppConstants.messageTemplatesTable, {
        'id': id,
        'title': title,
        'body': body,
        'use_contact_name': useName,
        'is_pinned': 0,
        'updated_at': now - i,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
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
          is_starred INTEGER DEFAULT 0,
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

      // Inbox thread-query composite indexes (v12)
      await _createThreadQueryIndexes(db);

      // «ستاره‌دار» index (v13)
      await _createStarredIndex(db);

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

      // Message templates + the built-ins the app ships with (v15)
      await _createMessageTemplatesTable(db);
      await _seedMessageTemplates(db);

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
