import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../constants/app_constants.dart';
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
        // The FTS availability flag is per *process*, not per database file, so
        // it has to be re-established on every open.
        onOpen: _probeMessageSearchFts,
      );
    } catch (e) {
      throw Exception('Failed to open database: $e');
    }
  }

  /// Sealed hidden-phonebook records — see
  /// [AppConstants.sealedQueueTable]. Byte-for-byte the DDL
  /// `hidden/SealedInbox.kt` runs, both `IF NOT EXISTS`.
  Future<void> _createSealedQueueTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.sealedQueueTable} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        blob BLOB NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Encrypted SMS waiting for the secure section — see
  /// [AppConstants.secureQueueTable]. The DDL is byte-for-byte the one
  /// `SecureSmsInbox.kt` runs, and both say `IF NOT EXISTS`: whichever side
  /// gets there first creates it.
  Future<void> _createSecureQueueTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.secureQueueTable} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        address TEXT NOT NULL,
        body TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        subscription_id INTEGER,
        received_at INTEGER NOT NULL,
        UNIQUE (address, body)
      )
    ''');
  }

  /// Threads the user marked unread by hand.
  ///
  /// See [AppConstants.unreadMarksTable]. A row here means "I have not dealt
  /// with this yet"; it deliberately flags **no message**, because flagging one
  /// is what made the mark indistinguishable from a message that had actually
  /// arrived — and made the inbox draw a count for something nobody sent.
  Future<void> _createUnreadMarksTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.unreadMarksTable} (
        thread_id TEXT PRIMARY KEY,
        marked_at INTEGER NOT NULL
      )
    ''');
  }

  /// Last known «normalized number → contact» of the device address book.
  ///
  /// A pure cache of what `flutter_contacts` last handed back — see
  /// [AppConstants.contactNameCacheTable]. `normalized` is the canonical
  /// national key (`PhoneNormalizer.toThreadId`), the same one
  /// `messages.thread_id`, `blocked_numbers.normalized` and
  /// `favorites.normalized` use, so a lookup is one indexed hit and no caller
  /// has to care what format the number was written in.
  ///
  /// `contact_id` rides along because the row is also what the avatar is loaded
  /// by; without it the first paint would show initials and swap in the photo
  /// a beat later, which is the same flicker one level down.
  Future<void> _createContactNameCacheTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.contactNameCacheTable} (
        normalized TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        contact_id TEXT
      )
    ''');
  }

  /// Which SIM each conversation last sent on.
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

  /// Speed dial: what each keypad digit ۲–۹ dials when it is held down.
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

  /// «پیام گروهی»: a group conversation, its members, and the real SMS
  /// each group message fanned out into.
  ///
  /// The group is **local**. There is no MMS in this app, so there is no
  /// provider thread that could hold several recipients and no way for a reply
  /// to come back into one — a member's answer lands in that member's own 1:1
  /// conversation, exactly as Google Messages behaves with «Group MMS» off. What
  /// this buys is the half that *is* real: one place to write to everybody, one
  /// history of what was written, one row in the inbox.
  ///
  /// `message_group_targets` is the load-bearing table. One group message =
  /// one row in `messages` (`device_sms_id` NULL) + N provider rows, and the
  /// mirror-sync diffs the provider's id list against the ids the app knows. If
  /// those N ids were not recorded anywhere, the very next sync would treat them
  /// as new messages and import a copy into each member's 1:1 chat.
  Future<void> _createMessageGroupTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.messageGroupsTable} (
        id TEXT PRIMARY KEY,
        -- NULL until the user names it: the title is then derived from the
        -- members, so renaming a contact renames the group too.
        title TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.messageGroupMembersTable} (
        group_id TEXT NOT NULL,
        -- PhoneNormalizer.toThreadId — the same canonical key as
        -- messages.thread_id, so a member added from a call log and the same
        -- person added from Contacts are one row.
        normalized TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        -- Denormalized on purpose (same reason as speed_dial): the inbox row and
        -- the chat header have to name the group before the address book has
        -- been read, and a member who is not (or no longer) a contact still has
        -- to read as something.
        display_name TEXT,
        added_at INTEGER NOT NULL,
        PRIMARY KEY (group_id, normalized)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${AppConstants.messageGroupTargetsTable} (
        message_id TEXT NOT NULL,
        normalized TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        -- pending | sent | delivered | failed, per recipient. The bubble shows
        -- the aggregate; «اطلاعات» shows this.
        status TEXT NOT NULL,
        -- The provider row this recipient's SMS became. NULL when the write-
        -- through did not happen (not the default SMS app) or the send failed.
        device_sms_id INTEGER,
        subscription_id INTEGER,
        -- Per-recipient tracking id handed to the native send, so a carrier
        -- delivery report finds this exact recipient rather than the whole
        -- group message.
        tracking_id TEXT,
        PRIMARY KEY (message_id, normalized)
      )
    ''');
    // The mirror-sync's known-id union reads this by device_sms_id.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_group_targets_device
      ON ${AppConstants.messageGroupTargetsTable}(device_sms_id)
    ''');
    // Delivery reports arrive keyed by tracking id.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_group_targets_tracking
      ON ${AppConstants.messageGroupTargetsTable}(tracking_id)
    ''');
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
  /// A failure must not abort creating the database — the app works without
  /// it.
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

  /// Establishes [messageSearchFtsReady] on every open (the flag is per
  /// process), and makes the index if the database has none.
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

  /// The index backing the message-body search walk.
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

  /// The index backing the «ستاره‌دار» screen.
  Future<void> _createStarredIndex(Database db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_is_starred
      ON ${AppConstants.messagesTable}(is_starred, timestamp DESC)
    ''');
  }

  /// The inbox thread-query composite indexes.
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
      batch.insert(AppConstants.messageTemplatesTable, {
        'id': template.id,
        'title': template.title,
        'body': template.body,
        'use_contact_name': template.useContactName ? 1 : 0,
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
        claimed_at INTEGER,
        -- SIM to send on. NULL = whichever the system default is at
        -- delivery time.
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
          -- Subscription id of the SIM this message went out on / came in on.
          -- NULL = unknown: a provider row the carrier left unstamped. Never treat NULL as "SIM 1" — a wrong SIM badge is
          -- worse than none.
          subscription_id INTEGER,
          -- 0 until this row's folded body is in `message_search`. Rows
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

      // Unique content index. Prevents duplicate rows when a
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

      // Inbox thread-query composite indexes
      await _createThreadQueryIndexes(db);

      // «ستاره‌دار» index
      await _createStarredIndex(db);

      // Message-body search walk
      await _createMessageSearchIndex(db);

      // Message-body substring index + its backlog flag
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
          -- Subscription id of the SIM the call used, resolved from the device
          -- call log's PHONE_ACCOUNT_ID. NULL = unknown / not a SIM call.
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

      // Message templates + the built-ins the app ships with
      await _createMessageTemplatesTable(db);
      await _seedMessageTemplates(db);

      // Scheduled outgoing messages
      await _createScheduledMessagesTable(db);

      // Per-conversation SIM memory
      await _createThreadSimTable(db);

      // Speed dial
      await _createSpeedDialTable(db);

      // Local group conversations + fan-out bookkeeping
      await _createMessageGroupTables(db);

      // Persisted address-book name cache
      await _createContactNameCacheTable(db);

      // Hand-marked unread threads
      await _createUnreadMarksTable(db);

      // Encrypted SMS waiting for the secure section
      await _createSecureQueueTable(db);

      // Sealed hidden-phonebook records
      await _createSealedQueueTable(db);
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
