class AppConstants {
  static const String appNamePersian = 'هم‌رسان';

  // Database
  static const String databaseName = 'communication_app.db';
  static const int databaseVersion = 26;

  // Tables
  static const String contactsTable = 'contacts';
  static const String messagesTable = 'messages';
  static const String callLogsTable = 'call_logs';
  static const String favoritesTable = 'favorites';
  static const String blockedNumbersTable = 'blocked_numbers';
  static const String archivedThreadsTable = 'archived_threads';
  static const String pinnedThreadsTable = 'pinned_threads';

  /// Threads the user marked unread **by hand** (v24).
  ///
  /// A mark, not a count: it is what tells «علامت‌گذاری نخوانده» apart from a
  /// message that genuinely arrived, so the inbox can draw a bare dot for the
  /// first and the real number for the second. Nothing in the `messages` table
  /// can express that difference — an unread row is an unread row.
  static const String unreadMarksTable = 'unread_marks';
  static const String draftsTable = 'drafts';
  static const String messageCategoriesTable = 'message_categories';
  static const String messageTemplatesTable = 'message_templates';
  static const String scheduledMessagesTable = 'scheduled_messages';

  /// Which SIM each conversation last sent on (v20). Google Messages remembers
  /// the choice per conversation, not globally.
  static const String threadSimTable = 'thread_sim';

  /// Speed dial (v21): the number each keypad digit ۲–۹ calls when held.
  /// The digit itself is the primary key — there are eight of them and a
  /// position can hold exactly one number.
  static const String speedDialTable = 'speed_dial';

  /// «پیام گروهی» (v22) — a group *conversation* that this app maintains
  /// locally, because there is no MMS to carry a real one.
  ///
  /// A group thread's `messages.thread_id` is `'g:' || message_groups.id` (see
  /// `GroupThread`), so every existing inbox/search/pin/archive query keeps
  /// working on it unchanged — it is just another thread id that happens not to
  /// be a phone number.
  static const String messageGroupsTable = 'message_groups';

  /// Who is in a group. `normalized` is the canonical thread id
  /// (`PhoneNormalizer.toThreadId`) so «+98912…» and «0912…» are one member.
  static const String messageGroupMembersTable = 'message_group_members';

  /// One row per recipient per group message: the real SMS that carried it.
  ///
  /// This is what makes the fan-out safe. A group send writes **one** row in
  /// `messages` but puts **N** rows into `content://sms`, and only one
  /// `device_sms_id` fits on a message row — without these the mirror-sync would
  /// see the other N-1 provider rows as unknown and import the message again
  /// into each member's 1:1 conversation. `MessageRepository.knownDeviceSmsIds`
  /// unions this table for exactly that reason.
  static const String messageGroupTargetsTable = 'message_group_targets';

  /// FTS5 index over the folded text of every message body — the substring
  /// index the message search uses when the device's SQLite can build one.
  /// See `DatabaseHelper.messageSearchFtsReady`.
  static const String messageSearchTable = 'message_search';

  /// Last known «normalized number → contact» of the device address book (v23).
  ///
  /// A *cache*, never a source of truth: the address book is on the other side
  /// of a platform channel and reading it whole takes long enough that the
  /// inbox and «اخیر» painted their rows as bare numbers and dropped the names
  /// in a beat later — visible on every single launch. This table is read from
  /// the database that is already open, so the first paint after a restart
  /// carries the names the last run resolved, and the real read then corrects
  /// it (silently, when nothing changed — the states are Equatable).
  static const String contactNameCacheTable = 'contact_name_cache';

  /// Encrypted SMS waiting for the secure section (v25): **ciphertext only**,
  /// as it arrived. The native receivers write it while the app is dead and
  /// the section locked (they cannot decrypt); `SecureMessenger` drains it
  /// into `secure.db` when the section is open. MIRRORED in
  /// `smscrypto/SecureSmsInbox.kt`, which also creates it `IF NOT EXISTS`.
  static const String secureQueueTable = 'secure_queue';

  /// What happened with a hidden-phonebook number while the section was
  /// locked (v26): calls and SMS, each **sealed** to the section's public key
  /// (`SealedBox`) — only `kind` is in the clear. Written by Kotlin
  /// (`hidden/SealedInbox.kt`, which mirrors this DDL and also creates it
  /// `IF NOT EXISTS`), drained into `secure.db` on the next unlock.
  static const String sealedQueueTable = 'sealed_queue';

  // Storage Keys
  static const String pinKey = 'app_pin';
  static const String patternKey = 'app_pattern';
  static const String authTypeKey = 'auth_type';
  static const String isAuthenticatedKey = 'is_authenticated';

  /// Set when the user chose «ادامه بدون رمز» on first entry (or removed the
  /// PIN later). Auth setup is never re-prompted while this is true; the PIN
  /// can still be set from Settings.
  static const String authSkippedKey = 'auth_skipped';

  /// Hash of the one-time recovery code that can reset a forgotten PIN. There
  /// is no account and no server behind this app, so the code the user wrote
  /// down at setup is the only way back in — see `AuthRepository`.
  static const String recoveryCodeKey = 'auth_recovery_code';

  /// Digits in the stored PIN (4, or 6 in the secure editions). Absent for a
  /// PIN saved before lengths were recorded, which is 4. See `PinPolicy`.
  static const String pinLengthKey = 'auth_pin_length';

  /// The inter-organizational activation code (secure storage). The code
  /// itself, re-verified against the device on every read — never a flag.
  /// See `ActivationRepository`.
  static const String interOrgActivationKey = 'inter_org_activation_code';

  // Auth Types
  static const String authTypePin = 'pin';
  static const String authTypePattern = 'pattern';

  // Persian Numbers
  static const Map<String, String> persianNumbers = {
    '0': '۰',
    '1': '۱',
    '2': '۲',
    '3': '۳',
    '4': '۴',
    '5': '۵',
    '6': '۶',
    '7': '۷',
    '8': '۸',
    '9': '۹',
  };

  // Persian Letters for Avatar Colors
  static const List<int> avatarColors = [
    0xFFE91E63, // Pink
    0xFF8BC34A, // Olive Green
    0xFF2196F3, // Blue
    0xFFFF9800, // Orange
    0xFF9C27B0, // Purple
    0xFF009688, // Teal
  ];
}
