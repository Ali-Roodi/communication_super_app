import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../constants/app_constants.dart';
import '../utils/phone_normalizer.dart';
import 'package:communication_super_app/features/messages/models/built_in_templates.dart';

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
        // The FTS availability flag is per *process*, not per database file, so
        // it has to be re-established on every open — and a database created on
        // a build/device that could not make the index gets another chance here.
        onOpen: _probeMessageSearchFts,
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

    // v16: blocked_numbers gains the spam-report columns, and — the actual bug
    // fix — every existing `normalized` value is rewritten into the canonical
    // thread-id form.
    if (oldVersion < 16) {
      // Conditional: an upgrade from < 5 has just created the table through
      // `_createBlockedNumbersTable`, which already declares both columns.
      // ALTERing them again is a hard error that would abort the whole upgrade.
      final columns = await _columnsOf(db, AppConstants.blockedNumbersTable);
      if (!columns.contains('is_spam')) {
        await db.execute('''
          ALTER TABLE ${AppConstants.blockedNumbersTable}
          ADD COLUMN is_spam INTEGER NOT NULL DEFAULT 0
        ''');
      }
      if (!columns.contains('reported_at')) {
        await db.execute('''
          ALTER TABLE ${AppConstants.blockedNumbersTable}
          ADD COLUMN reported_at INTEGER
        ''');
      }
      await _renormalizeBlockedNumbers(db);
    }

    // v17: the index the message-body search walks.
    if (oldVersion < 17) {
      await _createMessageSearchIndex(db);
    }

    // v18: the FTS5 substring index over message bodies, plus the per-row flag
    // that tracks what is in it.
    //
    // Existing rows are deliberately left `search_indexed = 0` rather than
    // folded here: a full mailbox is tens of thousands of rows and this runs
    // while the database is being opened, i.e. on the path to the first frame.
    // `MessageRepository.syncSearchIndex` fills the index in bounded batches in
    // the background, and the search keeps using the scan until it is complete
    // (see `MessageRepository.searchIndexReady`) so no message is ever missed
    // mid-backfill.
    if (oldVersion < 18) {
      final columns = await _columnsOf(db, AppConstants.messagesTable);
      if (!columns.contains('search_indexed')) {
        await db.execute('''
          ALTER TABLE ${AppConstants.messagesTable}
          ADD COLUMN search_indexed INTEGER NOT NULL DEFAULT 0
        ''');
      }
      await _createSearchIndexedIndex(db);
      await _createMessageSearchFts(db);
    }

    // v19: `favorites.normalized` becomes the canonical national form, for the
    // same reason `blocked_numbers.normalized` did in v16 — it is a UNIQUE key,
    // and a raw digits-only strip let one person be starred twice.
    if (oldVersion < 19) {
      await _renormalizeFavorites(db);
    }

    if (oldVersion < 20) {
      // Dual SIM. Guarded with _columnsOf for the same reason every other
      // ALTER here is: an unconditional ADD COLUMN on a table an earlier step
      // of this same upgrade may have just created at its newest shape aborts
      // the whole migration.
      await _addColumnIfMissing(
        db,
        AppConstants.messagesTable,
        'subscription_id',
        'INTEGER',
      );
      await _addColumnIfMissing(
        db,
        AppConstants.scheduledMessagesTable,
        'subscription_id',
        'INTEGER',
      );
      // `call_logs.sim_slot` is left in place but is no longer read or
      // written: it held a *faked* slot (1 whenever the device reported any
      // SIM name at all), so every call on either card claimed «سیم ۱».
      // Dropping the column would mean rebuilding the table for a value
      // nothing believes; the real answer now lives in `subscription_id`,
      // resolved from the call log's PHONE_ACCOUNT_ID.
      await _addColumnIfMissing(
        db,
        AppConstants.callLogsTable,
        'subscription_id',
        'INTEGER',
      );
      await _createThreadSimTable(db);
    }

    // v21: speed dial — one contact per keypad digit ۲–۹.
    if (oldVersion < 21) {
      await _createSpeedDialTable(db);
    }
  }

  /// ALTERs [table] only when [column] is not already there.
  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    final columns = await _columnsOf(db, table);
    if (columns.contains(column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  /// Which SIM each conversation last sent on (v20).
  ///
  /// Google Messages remembers the SIM **per conversation**, not globally: a
  /// work number is answered from the work SIM even when the other card is the
  /// system default. The row is written on send, so it always reflects what
  /// actually went out rather than what was once picked.
  ///
  /// Keyed by `thread_id` — the same canonical `09xxxxxxxxx` as
  /// `messages.thread_id`.
  Future<void> _createThreadSimTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.threadSimTable} (
        thread_id TEXT PRIMARY KEY,
        subscription_id INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// Speed dial (v21): what each keypad digit ۲–۹ dials when it is held down.
  ///
  /// `position` **is** the primary key — a digit holds exactly one number, and
  /// assigning a new contact to a key replaces what was there. `۱` is not a
  /// position: it is voicemail on every phone ever made, and `۰` types «+».
  ///
  /// The name is denormalized on purpose. The manage screen and the keypad's
  /// confirmation both have to say who is about to be called *before* the
  /// address book has been read — and a contact deleted from the phone must
  /// still leave a usable number on the key rather than a blank row.
  Future<void> _createSpeedDialTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.speedDialTable} (
        position INTEGER PRIMARY KEY,
        phone_number TEXT NOT NULL,
        name TEXT,
        contact_id TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// Rewrites `favorites.normalized` into `PhoneNormalizer.toNational` form
  /// (v19), collapsing the duplicate rows that the old raw-digits key allowed.
  ///
  /// Same shape as [_renormalizeBlockedNumbers]: recomputing has to happen in
  /// Dart, and it can collide on a UNIQUE column, so the oldest row wins and the
  /// duplicate is dropped — the user simply loses a redundant star.
  Future<void> _renormalizeFavorites(Database db) async {
    final rows = await db.query(
      AppConstants.favoritesTable,
      columns: ['id', 'phone_number', 'normalized', 'created_at'],
      orderBy: 'created_at ASC',
    );
    if (rows.isEmpty) return;

    final keep = <String>{};
    final drop = <String>[];
    final rewrite = <String, String>{};

    for (final row in rows) {
      final id = row['id'] as String;
      final source = (row['phone_number'] as String?)?.trim();
      final raw = (source == null || source.isEmpty)
          ? (row['normalized'] as String? ?? '')
          : source;
      final canonical = PhoneNormalizer.toNational(raw);
      if (canonical.isEmpty || !keep.add(canonical)) {
        drop.add(id);
        continue;
      }
      if (canonical != row['normalized']) rewrite[id] = canonical;
    }

    if (drop.isEmpty && rewrite.isEmpty) return;

    final batch = db.batch();
    for (final id in drop) {
      batch.delete(
        AppConstants.favoritesTable,
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    for (final entry in rewrite.entries) {
      batch.update(
        AppConstants.favoritesTable,
        {'normalized': entry.value},
        where: 'id = ?',
        whereArgs: [entry.key],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Column names of [table], for migrations that may run after the table was
  /// created at its newest shape by an earlier step of the same upgrade.
  Future<Set<String>> _columnsOf(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return {for (final row in rows) row['name'] as String};
  }

  /// Rewrites `blocked_numbers.normalized` into `PhoneNormalizer.toThreadId`
  /// form (v16).
  ///
  /// Rows written before v16 hold a raw digits-only strip of whatever string the
  /// caller happened to have — `989121234567` when blocked from a conversation
  /// (carrier E.164), `09121234567` when typed into the blocked-numbers screen.
  /// Every lookup asks for the thread-id form, so the first kind of row was
  /// dead weight: the number stayed blocked in the list and kept getting
  /// through. Recomputing has to happen here in Dart — `toThreadId` is not
  /// expressible in the SQL this migration could run — and it can collide,
  /// because two rows that differed only in formatting normalize to one key on a
  /// UNIQUE column. The older row (smaller `created_at`) wins and the duplicate
  /// is dropped, so the user's list simply loses a redundant entry.
  Future<void> _renormalizeBlockedNumbers(Database db) async {
    final rows = await db.query(
      AppConstants.blockedNumbersTable,
      columns: ['id', 'phone_number', 'normalized', 'created_at'],
      orderBy: 'created_at ASC',
    );
    if (rows.isEmpty) return;

    final keep = <String, String>{}; // canonical key → winning row id
    final drop = <String>[];
    final rewrite = <String, String>{}; // row id → canonical key

    for (final row in rows) {
      final id = row['id'] as String;
      // Prefer the display number: it is the string the user actually blocked,
      // so it still carries a country code / trunk zero the stripped column
      // may have lost.
      final source = (row['phone_number'] as String?)?.trim();
      final raw = (source == null || source.isEmpty)
          ? (row['normalized'] as String? ?? '')
          : source;
      final canonical = PhoneNormalizer.toThreadId(raw);
      if (canonical.isEmpty) {
        drop.add(id);
        continue;
      }
      if (keep.containsKey(canonical)) {
        drop.add(id);
        continue;
      }
      keep[canonical] = id;
      if (canonical != row['normalized']) rewrite[id] = canonical;
    }

    if (drop.isEmpty && rewrite.isEmpty) return;

    final batch = db.batch();
    for (final id in drop) {
      batch.delete(
        AppConstants.blockedNumbersTable,
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    for (final entry in rewrite.entries) {
      batch.update(
        AppConstants.blockedNumbersTable,
        {'normalized': entry.value},
        where: 'id = ?',
        whereArgs: [entry.key],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Whether this process can use the FTS5 substring index.
  ///
  /// False on any device whose bundled SQLite has no FTS5 or no `trigram`
  /// tokenizer — trigram needs SQLite 3.34, i.e. Android 12, and this app ships
  /// to minSdk 24. The search silently falls back to its bounded scan there, so
  /// this is a *speed* switch and never a correctness one.
  static bool _ftsAvailable = false;
  static bool get messageSearchFtsReady => _ftsAvailable;

  /// Creates the FTS5 index, or records that this device cannot have one.
  ///
  /// `trigram` is the only tokenizer that makes FTS5 a real **substring** index;
  /// the default tokenizers match whole tokens or prefixes, which would miss
  /// «جلس» inside «مجلس» and turn the index into a source of false negatives.
  /// A failure must not abort the migration — the app works without it.
  Future<void> _createMessageSearchFts(Database db) async {
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS ${AppConstants.messageSearchTable}
        USING fts5(folded, tokenize='trigram')
      ''');
      _ftsAvailable = true;
    } catch (e) {
      _ftsAvailable = false;
      debugPrint(
        'FTS5 trigram index unavailable; search falls back to scan: $e',
      );
    }
  }

  /// Establishes [messageSearchFtsReady] on every open, and retries the create
  /// for a database whose migration ran on a build that could not make it.
  Future<void> _probeMessageSearchFts(Database db) async {
    try {
      await db.rawQuery(
        'SELECT rowid FROM ${AppConstants.messageSearchTable} LIMIT 1',
      );
      _ftsAvailable = true;
    } catch (_) {
      await _createMessageSearchFts(db);
    }
  }

  /// Lets the indexer find its backlog without scanning the table.
  Future<void> _createSearchIndexedIndex(Database db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_search_pending
      ON ${AppConstants.messagesTable}(search_indexed)
    ''');
  }

  /// v17 index backing the message-body search walk.
  ///
  /// `MessageRepository._scanBodies` reads the prefiltered rows newest-first and
  /// throws away the soft-deleted ones. `idx_messages_timestamp` gives it the
  /// ordering but not the filter, so every tombstone in the mailbox was read and
  /// rejected on the way; leading with `is_deleted` lets SQLite seek straight to
  /// the live rows and walk them in timestamp order without a sort.
  ///
  /// This is the *fallback* path's index — a query too short for the trigram FTS
  /// index still comes through here — so it stays even though the FTS index
  /// answers the normal case.
  Future<void> _createMessageSearchIndex(Database db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_search
      ON ${AppConstants.messagesTable}(is_deleted, timestamp DESC)
    ''');
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
        created_at INTEGER NOT NULL,
        is_spam INTEGER NOT NULL DEFAULT 0,
        reported_at INTEGER
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
  /// Seeds the built-in templates from [BuiltInTemplates.all].
  ///
  /// The list lives in Dart rather than here because the SMS wire format
  /// ([TemplateWire]) is bound to those same constants: a row and its wire
  /// definition drifting apart would make a received template decode into text
  /// its sender never wrote.
  Future<void> _seedMessageTemplates(Database db) async {
    final seeds = BuiltInTemplates.all;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    // Seeded newest-first in list order: each row is stamped a millisecond
    // older than the one before, so the board opens in the catalogue's order.
    for (var i = 0; i < seeds.length; i++) {
      final template = seeds[i];
      batch.insert(
        AppConstants.messageTemplatesTable,
        {
          'id': template.id,
          'title': template.title,
          'body': template.body,
          'use_contact_name': template.useContactName ? 1 : 0,
          'is_pinned': 0,
          'updated_at': now - i,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
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
        claimed_at INTEGER,
        -- SIM to send on (v20). NULL = whichever the system default is at
        -- delivery time, which is also what a row scheduled before dual-SIM
        -- support means.
        subscription_id INTEGER
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
          -- Subscription id of the SIM this message went out on / came in on
          -- (v20). NULL = unknown: every row that predates dual-SIM support,
          -- and anything imported from a provider row the carrier left
          -- unstamped. Never treat NULL as "SIM 1" — a wrong SIM badge is
          -- worse than none.
          subscription_id INTEGER,
          -- 0 until this row's folded body is in `message_search` (v18). Rows
          -- inserted natively (the scheduled worker, the notification reply)
          -- never set it, which is exactly how the indexer finds them.
          search_indexed INTEGER NOT NULL DEFAULT 0,
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

      // Message-body search walk (v17)
      await _createMessageSearchIndex(db);

      // Message-body substring index + its backlog flag (v18)
      await _createSearchIndexedIndex(db);
      await _createMessageSearchFts(db);

      // Call logs table (local cache)
      await db.execute('''
        CREATE TABLE ${AppConstants.callLogsTable} (
          id TEXT PRIMARY KEY,
          contact_id TEXT,
          phone_number TEXT NOT NULL,
          call_type TEXT NOT NULL,
          duration INTEGER,
          timestamp INTEGER NOT NULL,
          -- Legacy (<= v19) and unused: it stored a faked slot. Kept only so a
          -- fresh install and an upgraded database have the same shape.
          sim_slot INTEGER,
          -- Subscription id of the SIM the call used, resolved from the device
          -- call log's PHONE_ACCOUNT_ID (v20). NULL = unknown / not a SIM call.
          subscription_id INTEGER,
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

      // Per-conversation SIM memory (v20)
      await _createThreadSimTable(db);

      // Speed dial (v21)
      await _createSpeedDialTable(db);
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
