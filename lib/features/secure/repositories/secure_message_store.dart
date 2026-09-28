import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
// SQLCipher's API types — encrypted conversations live only in `secure.db`.
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import 'key_bank_repository.dart' show KeyBankLockedException;
import 'secure_store.dart';

/// Where an outgoing encrypted message is. Stored by name.
enum SecureMessageStatus {
  /// Waiting for a session (the handshake is still under way).
  queued,

  /// Encrypted and handed to the radio.
  sending,
  sent,
  delivered,

  /// The peer's «دیده شد» covered it.
  seen,
  failed,

  /// An incoming message.
  received,
}

class SecureConversation extends Equatable {
  const SecureConversation({
    required this.phone,
    required this.name,
    this.peerKeyId,
    this.peerPublic,
    this.ownKeyId,
    this.ownSource,
    required this.createdAt,
    required this.lastAt,
    this.unread = 0,
    this.lastBody,
    this.lastOutgoing = false,
    this.seenSid,
    this.seenCounter,
  });

  /// The peer's number, canonical — the conversation's key.
  final String phone;
  final String name;

  /// Null for a conversation without a key: a hidden contact the key bank
  /// does not know, reached by plain SMS (phase G).
  final String? peerKeyId;
  final Uint8List? peerPublic;

  /// Which of our identities talks to this peer, and where it comes from
  /// (`directory:<id>` or `group:<id>`); null without a key.
  final String? ownKeyId;
  final String? ownSource;

  /// Whether messages here are encrypted (else plain SMS).
  bool get encrypted =>
      peerKeyId != null && peerPublic != null && ownKeyId != null;
  final int createdAt;
  final int lastAt;
  final int unread;

  /// The newest message, for the inbox row (not stored in this table).
  final String? lastBody;
  final bool lastOutgoing;

  /// The last «دیده شد» we sent: session and counter it covered.
  final int? seenSid;
  final int? seenCounter;

  @override
  List<Object?> get props => [
    phone,
    name,
    peerKeyId,
    ownKeyId,
    ownSource,
    lastAt,
    unread,
    lastBody,
    lastOutgoing,
    seenSid,
    seenCounter,
  ];
}

class SecureMessage extends Equatable {
  const SecureMessage({
    required this.id,
    required this.phone,
    required this.outgoing,
    required this.body,
    required this.timestamp,
    required this.status,
    this.sid,
    this.counter,
    this.deleteAfterSeen = false,
    this.seenAt,
    this.parts,
    this.plain = false,
  });

  final String id;
  final String phone;
  final bool outgoing;
  final String body;
  final int timestamp;
  final SecureMessageStatus status;

  /// The session and counter it travelled with; null while still queued.
  final int? sid;
  final int? counter;
  final bool deleteAfterSeen;

  /// Incoming: when it was first on screen here.
  final int? seenAt;
  final int? parts;

  /// A plain (unencrypted) SMS with a hidden contact.
  final bool plain;

  static SecureMessage fromRow(Map<String, Object?> r) => SecureMessage(
    id: r['id'] as String,
    phone: r['phone'] as String,
    outgoing: r['outgoing'] == 1,
    body: r['body'] as String,
    timestamp: r['timestamp'] as int,
    status:
        SecureMessageStatus.values.asNameMap()[r['status']] ??
        SecureMessageStatus.failed,
    sid: r['sid'] as int?,
    counter: r['counter'] as int?,
    deleteAfterSeen: r['delete_after_seen'] == 1,
    seenAt: r['seen_at'] as int?,
    parts: r['parts'] as int?,
    plain: r['plain'] == 1,
  );

  @override
  List<Object?> get props => [
    id,
    phone,
    outgoing,
    body,
    timestamp,
    status,
    sid,
    counter,
    deleteAfterSeen,
    seenAt,
    parts,
    plain,
  ];
}

/// A stored ratchet state or pending handshake.
class StoredSession {
  const StoredSession({
    required this.phone,
    required this.sid,
    required this.pending,
    required this.state,
    required this.createdAt,
  });
  final String phone;
  final int sid;

  /// Our INIT, waiting for its RESPONSE.
  final bool pending;
  final Uint8List state;
  final int createdAt;
}

/// A packet taken from the main database's queue, not processed yet.
class InboxPacket {
  const InboxPacket({
    required this.id,
    required this.address,
    required this.body,
    required this.timestamp,
    required this.attempts,
  });
  final int id;
  final String address;
  final String body;
  final int timestamp;
  final int attempts;
}

/// Encrypted conversations, in `secure.db` (tables made by [SecureStore]).
/// Works only while the secure section is open; otherwise every call throws
/// [KeyBankLockedException].
class SecureMessageStore {
  SecureMessageStore({cipher.Database? Function()? database})
    : _database = database ?? (() => SecureStore.instance.database);

  final cipher.Database? Function() _database;

  cipher.Database get db =>
      _database() ?? (throw const KeyBankLockedException());

  // ── Conversations ────────────────────────────────────────────────────────

  Future<List<SecureConversation>> conversations() async {
    final rows = await db.rawQuery('''
      SELECT c.*,
             (SELECT m.body FROM sm_messages m WHERE m.phone = c.phone
               ORDER BY m.timestamp DESC LIMIT 1) AS last_body,
             (SELECT m.outgoing FROM sm_messages m WHERE m.phone = c.phone
               ORDER BY m.timestamp DESC LIMIT 1) AS last_outgoing
        FROM sm_conversations c
       ORDER BY c.last_at DESC
    ''');
    return rows.map(_conversation).toList();
  }

  Future<SecureConversation?> conversation(String phone) async {
    final rows = await db.query(
      'sm_conversations',
      where: 'phone = ?',
      whereArgs: [phone],
    );
    return rows.isEmpty ? null : _conversation(rows.first);
  }

  SecureConversation _conversation(Map<String, Object?> r) =>
      SecureConversation(
        phone: r['phone'] as String,
        name: r['name'] as String,
        peerKeyId: r['peer_key_id'] as String?,
        peerPublic: r['peer_public'] as Uint8List?,
        ownKeyId: r['own_key_id'] as String?,
        ownSource: r['own_source'] as String?,
        createdAt: r['created_at'] as int,
        lastAt: r['last_at'] as int,
        unread: r['unread'] as int,
        lastBody: r['last_body'] as String?,
        lastOutgoing: r['last_outgoing'] == 1,
        seenSid: r['seen_sid'] as int?,
        seenCounter: r['seen_counter'] as int?,
      );

  /// Creates the conversation, or re-binds an existing one to [peerPublic]
  /// (the peer's key changed — a re-issued key file). Re-binding drops the
  /// sessions made with the old key.
  Future<void> upsertConversation({
    required String phone,
    required String name,
    required String peerKeyId,
    required Uint8List peerPublic,
    required String ownKeyId,
    required String ownSource,
    required int now,
  }) => db.transaction((txn) async {
    final existing = await txn.query(
      'sm_conversations',
      columns: ['peer_key_id', 'own_key_id'],
      where: 'phone = ?',
      whereArgs: [phone],
    );
    if (existing.isEmpty) {
      await txn.insert('sm_conversations', {
        'phone': phone,
        'name': name,
        'peer_key_id': peerKeyId,
        'peer_public': peerPublic,
        'own_key_id': ownKeyId,
        'own_source': ownSource,
        'created_at': now,
        'last_at': now,
      });
      return;
    }
    final row = existing.first;
    if (row['peer_key_id'] == peerKeyId && row['own_key_id'] == ownKeyId) {
      await txn.update(
        'sm_conversations',
        {'name': name},
        where: 'phone = ?',
        whereArgs: [phone],
      );
      return;
    }
    await txn.update(
      'sm_conversations',
      {
        'name': name,
        'peer_key_id': peerKeyId,
        'peer_public': peerPublic,
        'own_key_id': ownKeyId,
        'own_source': ownSource,
        'seen_sid': null,
        'seen_counter': null,
      },
      where: 'phone = ?',
      whereArgs: [phone],
    );
    await txn.delete('sm_sessions', where: 'phone = ?', whereArgs: [phone]);
  });

  /// A conversation without a key (a hidden contact reached by plain SMS);
  /// an existing one — keyed or not — only takes the name.
  Future<void> ensurePlainConversation({
    required String phone,
    required String name,
    required int now,
  }) async {
    final inserted = await db.insert('sm_conversations', {
      'phone': phone,
      'name': name,
      'created_at': now,
      'last_at': now,
    }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);
    if (inserted == 0) await rename(phone, name);
  }

  Future<void> rename(String phone, String name) => db.update(
    'sm_conversations',
    {'name': name},
    where: 'phone = ?',
    whereArgs: [phone],
  );

  Future<void> touchConversation(String phone, int at, {bool unread = false}) =>
      db.rawUpdate(
        'UPDATE sm_conversations SET last_at = MAX(last_at, ?), '
        'unread = unread + ? WHERE phone = ?',
        [at, unread ? 1 : 0, phone],
      );

  Future<void> clearUnread(String phone) => db.update(
    'sm_conversations',
    {'unread': 0},
    where: 'phone = ?',
    whereArgs: [phone],
  );

  Future<void> setSeenMark(String phone, int sid, int counter) => db.update(
    'sm_conversations',
    {'seen_sid': sid, 'seen_counter': counter},
    where: 'phone = ?',
    whereArgs: [phone],
  );

  /// The conversation and everything in it: messages, sessions.
  Future<void> deleteConversation(String phone) => db.transaction((txn) async {
    for (final table in const ['sm_messages', 'sm_sessions']) {
      await txn.delete(table, where: 'phone = ?', whereArgs: [phone]);
    }
    await txn.delete(
      'sm_conversations',
      where: 'phone = ?',
      whereArgs: [phone],
    );
  });

  // ── Sessions ─────────────────────────────────────────────────────────────

  Future<List<StoredSession>> sessions(String phone) async {
    final rows = await db.query(
      'sm_sessions',
      where: 'phone = ?',
      whereArgs: [phone],
      orderBy: 'created_at DESC',
    );
    return [
      for (final r in rows)
        StoredSession(
          phone: r['phone'] as String,
          sid: r['sid'] as int,
          pending: r['pending'] == 1,
          state: r['state'] as Uint8List,
          createdAt: r['created_at'] as int,
        ),
    ];
  }

  Future<void> putSession(cipher.DatabaseExecutor txn, StoredSession session) =>
      txn.insert('sm_sessions', {
        'phone': session.phone,
        'sid': session.sid,
        'pending': session.pending ? 1 : 0,
        'state': session.state,
        'created_at': session.createdAt,
      }, conflictAlgorithm: cipher.ConflictAlgorithm.replace);

  Future<void> saveSession(StoredSession session) => putSession(db, session);

  /// Replaces only the ratchet state, keeping when the session was made.
  Future<void> updateSessionState(
    cipher.DatabaseExecutor txn,
    String phone,
    int sid,
    Uint8List state,
  ) => txn.update(
    'sm_sessions',
    {'state': state},
    where: 'phone = ? AND sid = ?',
    whereArgs: [phone, sid],
  );

  Future<void> deleteSession(String phone, int sid) => db.delete(
    'sm_sessions',
    where: 'phone = ? AND sid = ?',
    whereArgs: [phone, sid],
  );

  /// Keeps the newest [keep] established sessions (delayed messages of an
  /// older one can still be read) and every pending handshake.
  Future<void> pruneSessions(String phone, {int keep = 3}) => db.rawDelete(
    '''
    DELETE FROM sm_sessions WHERE phone = ? AND pending = 0 AND sid NOT IN
      (SELECT sid FROM sm_sessions WHERE phone = ? AND pending = 0
        ORDER BY created_at DESC LIMIT ?)
    ''',
    [phone, phone, keep],
  );

  // ── Messages ─────────────────────────────────────────────────────────────

  Future<List<SecureMessage>> messages(String phone) async {
    final rows = await db.query(
      'sm_messages',
      where: 'phone = ?',
      whereArgs: [phone],
      orderBy: 'timestamp, rowid',
    );
    return rows.map(SecureMessage.fromRow).toList();
  }

  Future<SecureMessage?> message(String id) async {
    final rows = await db.query(
      'sm_messages',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : SecureMessage.fromRow(rows.first);
  }

  Future<List<SecureMessage>> queued(String phone) async {
    final rows = await db.query(
      'sm_messages',
      where: 'phone = ? AND outgoing = 1 AND status = ?',
      whereArgs: [phone, SecureMessageStatus.queued.name],
      orderBy: 'timestamp, rowid',
    );
    return rows.map(SecureMessage.fromRow).toList();
  }

  Future<void> insertMessage(cipher.DatabaseExecutor txn, SecureMessage m) =>
      txn.insert('sm_messages', {
        'id': m.id,
        'phone': m.phone,
        'outgoing': m.outgoing ? 1 : 0,
        'body': m.body,
        'timestamp': m.timestamp,
        'status': m.status.name,
        'sid': m.sid,
        'counter': m.counter,
        'delete_after_seen': m.deleteAfterSeen ? 1 : 0,
        'seen_at': m.seenAt,
        'parts': m.parts,
        'plain': m.plain ? 1 : 0,
      }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);

  /// Whether this plain SMS is already stored — a carrier's second delivery,
  /// or a history row moved twice. (Encrypted ones are deduplicated by
  /// their session and counter.)
  Future<bool> hasPlain(
    String phone, {
    required bool outgoing,
    required String body,
    required int timestamp,
  }) async {
    final rows = await db.query(
      'sm_messages',
      columns: ['id'],
      where:
          'phone = ? AND outgoing = ? AND plain = 1 AND body = ? AND timestamp = ?',
      whereArgs: [phone, outgoing ? 1 : 0, body, timestamp],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> addMessage(SecureMessage m) => insertMessage(db, m);

  Future<void> markSending(
    cipher.DatabaseExecutor txn,
    String id, {
    required int sid,
    required int counter,
    required int parts,
  }) => txn.update(
    'sm_messages',
    {
      'status': SecureMessageStatus.sending.name,
      'sid': sid,
      'counter': counter,
      'parts': parts,
    },
    where: 'id = ?',
    whereArgs: [id],
  );

  /// Moves an outgoing message forward; never back (a late «sent» report
  /// must not undo «seen»).
  Future<bool> advanceStatus(String id, SecureMessageStatus to) async {
    final current = await message(id);
    if (current == null || !current.outgoing) return false;
    const order = [
      SecureMessageStatus.queued,
      SecureMessageStatus.sending,
      SecureMessageStatus.sent,
      SecureMessageStatus.delivered,
      SecureMessageStatus.seen,
    ];
    if (to != SecureMessageStatus.failed &&
        order.indexOf(to) <= order.indexOf(current.status)) {
      return false;
    }
    if (to == SecureMessageStatus.failed &&
        order.indexOf(current.status) >=
            order.indexOf(SecureMessageStatus.sent)) {
      return false;
    }
    await db.update(
      'sm_messages',
      {'status': to.name},
      where: 'id = ?',
      whereArgs: [id],
    );
    return true;
  }

  /// «دیده شد» from the peer: our messages of session [sid] up to [upTo].
  Future<int> markSeenByPeer(String phone, int sid, int upTo) => db.rawUpdate(
    '''
    UPDATE sm_messages SET status = ?
     WHERE phone = ? AND outgoing = 1 AND sid = ? AND counter <= ? AND status IN (?, ?, ?)
    ''',
    [
      SecureMessageStatus.seen.name,
      phone,
      sid,
      upTo,
      SecureMessageStatus.sending.name,
      SecureMessageStatus.sent.name,
      SecureMessageStatus.delivered.name,
    ],
  );

  /// Stamps incoming messages as shown; returns the ones just stamped.
  Future<List<SecureMessage>> markShown(String phone, int now) async {
    return db.transaction((txn) async {
      final rows = await txn.query(
        'sm_messages',
        where: 'phone = ? AND outgoing = 0 AND seen_at IS NULL',
        whereArgs: [phone],
      );
      await txn.update(
        'sm_messages',
        {'seen_at': now},
        where: 'phone = ? AND outgoing = 0 AND seen_at IS NULL',
        whereArgs: [phone],
      );
      return rows.map(SecureMessage.fromRow).toList();
    });
  }

  Future<void> deleteMessage(String id) =>
      db.delete('sm_messages', where: 'id = ?', whereArgs: [id]);

  /// «حذف برای هر دو» from the peer: their message [counter] of [sid].
  Future<int> deleteIncoming(String phone, int sid, int counter) => db.delete(
    'sm_messages',
    where: 'phone = ? AND outgoing = 0 AND sid = ? AND counter = ?',
    whereArgs: [phone, sid, counter],
  );

  /// «حذف پس از دیدن»: incoming messages that asked for it and were shown.
  Future<int> deleteSeenEphemeral(String phone) => db.delete(
    'sm_messages',
    where:
        'phone = ? AND outgoing = 0 AND delete_after_seen = 1 AND seen_at IS NOT NULL',
    whereArgs: [phone],
  );

  // ── Inbox (packets not processed yet) ──────────────────────────────────────

  Future<void> addToInbox(List<InboxPacket> packets, int now) async {
    final batch = db.batch();
    for (final p in packets) {
      batch.insert('sm_inbox', {
        'address': p.address,
        'body': p.body,
        'timestamp': p.timestamp,
        'received_at': now,
      }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<List<InboxPacket>> inbox() async {
    final rows = await db.query('sm_inbox', orderBy: 'id');
    return [
      for (final r in rows)
        InboxPacket(
          id: r['id'] as int,
          address: r['address'] as String,
          body: r['body'] as String,
          timestamp: r['timestamp'] as int,
          attempts: r['attempts'] as int,
        ),
    ];
  }

  Future<void> removeFromInbox(int id) =>
      db.delete('sm_inbox', where: 'id = ?', whereArgs: [id]);

  Future<void> retryLater(int id) => db.rawUpdate(
    'UPDATE sm_inbox SET attempts = attempts + 1 WHERE id = ?',
    [id],
  );

  /// Settings kept in `secure_meta`.
  Future<String?> meta(String key) async {
    final rows = await db.query(
      'secure_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value) => db.insert('secure_meta', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: cipher.ConflictAlgorithm.replace);
}
