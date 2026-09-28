import 'package:equatable/equatable.dart';
// SQLCipher's API types — encrypted groups live only in `secure.db`.
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import 'key_bank_repository.dart' show KeyBankLockedException;
import 'secure_message_store.dart' show SecureMessageStatus;
import 'secure_store.dart';

/// How members answer (stored as the index: 0 chat, 1 announce).
enum SecureGroupMode {
  /// A reply goes to every member.
  chat,

  /// A reply goes to the creator only.
  announce,
}

class SecureGroupMember extends Equatable {
  const SecureGroupMember({
    required this.phone,
    required this.keyId,
    this.infoVersion = 0,
    this.removed = false,
  });

  /// Canonical.
  final String phone;

  /// Hex; how every phone recognises the member (and itself).
  final String keyId;

  /// Creator side: the definition this member was last sent.
  final int infoVersion;

  /// Creator side: dropped, still to be told.
  final bool removed;

  @override
  List<Object?> get props => [phone, keyId, infoVersion, removed];
}

class SecureGroup extends Equatable {
  const SecureGroup({
    required this.id,
    required this.name,
    required this.mode,
    required this.version,
    required this.createdAt,
    required this.lastAt,
    this.creator,
    this.pendingInfo = false,
    this.left = false,
    this.unread = 0,
    this.members = const [],
    this.lastBody,
    this.lastSender,
    this.lastOutgoing = false,
  });

  /// Hex of the 8-byte group id.
  final String id;
  final String name;
  final SecureGroupMode mode;
  final int version;

  /// The creator's number; null when it is this phone.
  final String? creator;

  /// A message came before the definition: name and members are unknown.
  final bool pendingInfo;

  /// The creator's newest definition no longer lists this phone.
  final bool left;
  final int createdAt;
  final int lastAt;
  final int unread;

  /// Not removed ones; the creator is not among them.
  final List<SecureGroupMember> members;

  final String? lastBody;
  final String? lastSender;
  final bool lastOutgoing;

  bool get isMine => creator == null;

  /// Who a message of ours goes to: in a chat group everyone (the creator
  /// included, when it is not us); in an announcement list the members when
  /// we made it, else the creator only.
  List<String> get recipients {
    if (mode == SecureGroupMode.announce && !isMine) return [creator!];
    return [if (!isMine) creator!, for (final m in members) m.phone];
  }

  @override
  List<Object?> get props => [
    id,
    name,
    mode,
    version,
    creator,
    pendingInfo,
    left,
    createdAt,
    lastAt,
    unread,
    members,
    lastBody,
    lastSender,
    lastOutgoing,
  ];
}

/// One member's copy of an outgoing group message.
class GroupDelivery extends Equatable {
  const GroupDelivery({
    required this.messageId,
    required this.phone,
    required this.status,
    this.sid,
    this.counter,
    this.parts,
  });
  final String messageId;
  final String phone;
  final SecureMessageStatus status;
  final int? sid;
  final int? counter;
  final int? parts;

  @override
  List<Object?> get props => [messageId, phone, status, sid, counter, parts];
}

class SecureGroupMessage extends Equatable {
  const SecureGroupMessage({
    required this.id,
    required this.groupId,
    required this.body,
    required this.timestamp,
    required this.status,
    this.sender,
    this.sid,
    this.counter,
    this.deleteAfterSeen = false,
    this.seenAt,
    this.deliveries = const [],
  });

  final String id;
  final String groupId;

  /// Null for ours.
  final String? sender;
  final String body;
  final int timestamp;

  /// Incoming: [SecureMessageStatus.received]. Ours: see [deliveries].
  final SecureMessageStatus status;
  final int? sid;
  final int? counter;
  final bool deleteAfterSeen;
  final int? seenAt;
  final List<GroupDelivery> deliveries;

  bool get outgoing => sender == null;

  int count(SecureMessageStatus s) =>
      deliveries.where((d) => d.status == s).length;

  @override
  List<Object?> get props => [
    id,
    groupId,
    sender,
    body,
    timestamp,
    status,
    sid,
    counter,
    deleteAfterSeen,
    seenAt,
    deliveries,
  ];
}

/// Encrypted groups, in `secure.db` (tables made by [SecureStore]). Works only
/// while the secure section is open; otherwise every call throws
/// [KeyBankLockedException].
class SecureGroupStore {
  SecureGroupStore({cipher.Database? Function()? database})
    : _database = database ?? (() => SecureStore.instance.database);

  final cipher.Database? Function() _database;

  cipher.Database get db =>
      _database() ?? (throw const KeyBankLockedException());

  // ── Groups ───────────────────────────────────────────────────────────────

  Future<List<SecureGroup>> groups() async {
    final rows = await db.rawQuery('''
      SELECT g.*,
             (SELECT m.body FROM sg_messages m WHERE m.group_id = g.id
               ORDER BY m.timestamp DESC LIMIT 1) AS last_body,
             (SELECT m.sender FROM sg_messages m WHERE m.group_id = g.id
               ORDER BY m.timestamp DESC LIMIT 1) AS last_sender,
             (SELECT COUNT(*) FROM sg_messages m WHERE m.group_id = g.id) AS n
        FROM sg_groups g
       ORDER BY g.last_at DESC
    ''');
    final members = await _members();
    return [
      for (final r in rows)
        _group(
          r,
          members[r['id']] ?? const [],
          hasMessages: (r['n'] as int) > 0,
        ),
    ];
  }

  Future<SecureGroup?> group(String id) async {
    final rows = await db.query('sg_groups', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _group(rows.first, (await _members(id))[id] ?? const []);
  }

  SecureGroup _group(
    Map<String, Object?> r,
    List<SecureGroupMember> members, {
    bool hasMessages = false,
  }) => SecureGroup(
    id: r['id'] as String,
    name: r['name'] as String,
    mode: SecureGroupMode.values[r['mode'] as int],
    version: r['version'] as int,
    creator: r['creator'] as String?,
    pendingInfo: r['pending_info'] == 1,
    left: r['left_group'] == 1,
    createdAt: r['created_at'] as int,
    lastAt: r['last_at'] as int,
    unread: r['unread'] as int,
    members: [
      for (final m in members)
        if (!m.removed) m,
    ],
    lastBody: r['last_body'] as String?,
    lastSender: r['last_sender'] as String?,
    lastOutgoing: hasMessages && r['last_sender'] == null,
  );

  /// All member rows, removed ones included (creator side needs them).
  Future<List<SecureGroupMember>> allMembers(String groupId) async =>
      (await _members(groupId))[groupId] ?? const [];

  Future<Map<String, List<SecureGroupMember>>> _members([String? id]) async {
    final rows = await db.query(
      'sg_members',
      where: id == null ? null : 'group_id = ?',
      whereArgs: id == null ? null : [id],
      orderBy: 'group_id, position',
    );
    final out = <String, List<SecureGroupMember>>{};
    for (final r in rows) {
      out
          .putIfAbsent(r['group_id'] as String, () => [])
          .add(
            SecureGroupMember(
              phone: r['phone'] as String,
              keyId: r['key_id'] as String,
              infoVersion: r['info_version'] as int,
              removed: r['removed'] == 1,
            ),
          );
    }
    return out;
  }

  /// A group this phone makes.
  Future<void> createGroup({
    required String id,
    required String name,
    required SecureGroupMode mode,
    required List<({String phone, String keyId})> members,
    required int now,
  }) => db.transaction((txn) async {
    await txn.insert('sg_groups', {
      'id': id,
      'name': name,
      'mode': mode.index,
      'version': 1,
      'created_at': now,
      'last_at': now,
    });
    var position = 0;
    for (final m in members) {
      await txn.insert('sg_members', {
        'group_id': id,
        'phone': m.phone,
        'key_id': m.keyId,
        'position': position++,
      });
    }
  });

  /// The creator changes its group: a new version; dropped members are
  /// kept as `removed` until they have been told.
  Future<void> editGroup({
    required String id,
    required String name,
    required List<({String phone, String keyId})> members,
  }) => db.transaction((txn) async {
    await txn.rawUpdate(
      'UPDATE sg_groups SET name = ?, version = version + 1 WHERE id = ?',
      [name, id],
    );
    final keep = {for (final m in members) m.phone};
    final existing = await txn.query(
      'sg_members',
      columns: ['phone'],
      where: 'group_id = ?',
      whereArgs: [id],
    );
    for (final r in existing) {
      if (!keep.contains(r['phone'])) {
        await txn.update(
          'sg_members',
          {'removed': 1},
          where: 'group_id = ? AND phone = ?',
          whereArgs: [id, r['phone']],
        );
      }
    }
    var position = 0;
    for (final m in members) {
      await txn.insert('sg_members', {
        'group_id': id,
        'phone': m.phone,
        'key_id': m.keyId,
        'position': position++,
        'removed': 0,
      }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);
      await txn.update(
        'sg_members',
        {'position': position - 1, 'removed': 0, 'key_id': m.keyId},
        where: 'group_id = ? AND phone = ?',
        whereArgs: [id, m.phone],
      );
    }
  });

  /// A definition received from [sender]. Applied only when it is newer and
  /// comes from the group's creator (or decides the creator of a group known
  /// only from a message). Returns false when refused.
  Future<bool> applyInfo(
    cipher.DatabaseExecutor txn, {
    required String id,
    required String sender,
    required int version,
    required SecureGroupMode mode,
    required String name,
    required List<({String phone, String keyId})> members,
    required bool includesMe,
    required int now,
  }) async {
    final rows = await txn.query('sg_groups', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final g = rows.first;
      final pending = g['pending_info'] == 1;
      // Ours, or someone else's: only the creator defines a group.
      if (!pending && g['creator'] != sender) return false;
      if (!pending && version <= (g['version'] as int)) return false;
      await txn.update(
        'sg_groups',
        {
          'name': name,
          'mode': mode.index,
          'version': version,
          'creator': sender,
          'pending_info': 0,
          'left_group': includesMe ? 0 : 1,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } else {
      await txn.insert('sg_groups', {
        'id': id,
        'name': name,
        'mode': mode.index,
        'version': version,
        'creator': sender,
        'left_group': includesMe ? 0 : 1,
        'created_at': now,
        'last_at': now,
      });
    }
    await txn.delete('sg_members', where: 'group_id = ?', whereArgs: [id]);
    var position = 0;
    for (final m in members) {
      await txn.insert('sg_members', {
        'group_id': id,
        'phone': m.phone,
        'key_id': m.keyId,
        'position': position++,
      }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);
    }
    return true;
  }

  /// A message for a group whose definition has not arrived yet.
  Future<void> ensurePlaceholder(
    cipher.DatabaseExecutor txn,
    String id,
    int now,
  ) => txn.insert('sg_groups', {
    'id': id,
    'name': '',
    'mode': SecureGroupMode.chat.index,
    'version': 0,
    'pending_info': 1,
    'created_at': now,
    'last_at': now,
  }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);

  /// Creator side: [phone] now has definition [version]; a removed member
  /// who has been told is dropped for good.
  Future<void> markInfoSent(String groupId, String phone, int version) =>
      db.transaction((txn) async {
        await txn.delete(
          'sg_members',
          where: 'group_id = ? AND phone = ? AND removed = 1',
          whereArgs: [groupId, phone],
        );
        await txn.update(
          'sg_members',
          {'info_version': version},
          where: 'group_id = ? AND phone = ?',
          whereArgs: [groupId, phone],
        );
      });

  /// Creator side: groups whose newest definition [phone] has not had.
  Future<List<SecureGroup>> staleInfoFor(String phone) async {
    final rows = await db.rawQuery(
      '''
      SELECT g.* FROM sg_groups g JOIN sg_members m ON m.group_id = g.id
       WHERE g.creator IS NULL AND m.phone = ? AND m.info_version < g.version
      ''',
      [phone],
    );
    return [
      for (final r in rows)
        _group(r, (await _members(r['id'] as String))[r['id']] ?? const []),
    ];
  }

  Future<void> touch(
    String id,
    int at, {
    bool unread = false,
    cipher.DatabaseExecutor? txn,
  }) => (txn ?? db).rawUpdate(
    'UPDATE sg_groups SET last_at = MAX(last_at, ?), unread = unread + ? '
    'WHERE id = ?',
    [at, unread ? 1 : 0, id],
  );

  Future<void> clearUnread(String id) =>
      db.update('sg_groups', {'unread': 0}, where: 'id = ?', whereArgs: [id]);

  /// On this phone only.
  Future<void> deleteGroup(String id) => db.transaction((txn) async {
    await txn.rawDelete(
      'DELETE FROM sg_deliveries WHERE message_id IN '
      '(SELECT id FROM sg_messages WHERE group_id = ?)',
      [id],
    );
    for (final table in const ['sg_messages', 'sg_members']) {
      await txn.delete(table, where: 'group_id = ?', whereArgs: [id]);
    }
    await txn.delete('sg_groups', where: 'id = ?', whereArgs: [id]);
  });

  // ── Messages ─────────────────────────────────────────────────────────────

  Future<List<SecureGroupMessage>> messages(String groupId) async {
    final rows = await db.query(
      'sg_messages',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'timestamp, rowid',
    );
    final deliveries = await _deliveries(
      rows.where((r) => r['sender'] == null).map((r) => r['id'] as String),
    );
    return [for (final r in rows) _message(r, deliveries[r['id']])];
  }

  Future<SecureGroupMessage?> message(String id) async {
    final rows = await db.query(
      'sg_messages',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return _message(rows.first, (await _deliveries([id]))[id]);
  }

  SecureGroupMessage _message(
    Map<String, Object?> r,
    List<GroupDelivery>? deliveries,
  ) => SecureGroupMessage(
    id: r['id'] as String,
    groupId: r['group_id'] as String,
    sender: r['sender'] as String?,
    body: r['body'] as String,
    timestamp: r['timestamp'] as int,
    status:
        SecureMessageStatus.values.asNameMap()[r['status']] ??
        SecureMessageStatus.failed,
    sid: r['sid'] as int?,
    counter: r['counter'] as int?,
    deleteAfterSeen: r['delete_after_seen'] == 1,
    seenAt: r['seen_at'] as int?,
    deliveries: deliveries ?? const [],
  );

  Future<Map<String, List<GroupDelivery>>> _deliveries(
    Iterable<String> ids,
  ) async {
    final list = ids.toList();
    if (list.isEmpty) return const {};
    final rows = await db.query(
      'sg_deliveries',
      where: 'message_id IN (${List.filled(list.length, '?').join(',')})',
      whereArgs: list,
    );
    final out = <String, List<GroupDelivery>>{};
    for (final r in rows) {
      out.putIfAbsent(r['message_id'] as String, () => []).add(_delivery(r));
    }
    return out;
  }

  GroupDelivery _delivery(Map<String, Object?> r) => GroupDelivery(
    messageId: r['message_id'] as String,
    phone: r['phone'] as String,
    status:
        SecureMessageStatus.values.asNameMap()[r['status']] ??
        SecureMessageStatus.failed,
    sid: r['sid'] as int?,
    counter: r['counter'] as int?,
    parts: r['parts'] as int?,
  );

  /// Ours, queued for each of [recipients].
  Future<void> addOutgoing(SecureGroupMessage m, List<String> recipients) =>
      db.transaction((txn) async {
        await txn.insert('sg_messages', _row(m));
        for (final phone in recipients) {
          await txn.insert('sg_deliveries', {
            'message_id': m.id,
            'phone': phone,
            'status': SecureMessageStatus.queued.name,
          });
        }
      });

  Future<void> addIncoming(cipher.DatabaseExecutor txn, SecureGroupMessage m) =>
      txn.insert(
        'sg_messages',
        _row(m),
        conflictAlgorithm: cipher.ConflictAlgorithm.ignore,
      );

  Map<String, Object?> _row(SecureGroupMessage m) => {
    'id': m.id,
    'group_id': m.groupId,
    'sender': m.sender,
    'body': m.body,
    'timestamp': m.timestamp,
    'status': m.status.name,
    'sid': m.sid,
    'counter': m.counter,
    'delete_after_seen': m.deleteAfterSeen ? 1 : 0,
    'seen_at': m.seenAt,
  };

  /// Deliveries to [phone] still waiting for a session, oldest first, with
  /// what they carry.
  Future<List<({GroupDelivery delivery, SecureGroupMessage message})>>
  queuedFor(String phone) async {
    final rows = await db.rawQuery(
      '''
      SELECT d.*, m.group_id, m.sender, m.body, m.timestamp, m.status AS m_status,
             m.delete_after_seen, m.seen_at, m.sid AS m_sid, m.counter AS m_counter
        FROM sg_deliveries d JOIN sg_messages m ON m.id = d.message_id
       WHERE d.phone = ? AND d.status = ?
       ORDER BY m.timestamp, m.rowid
      ''',
      [phone, SecureMessageStatus.queued.name],
    );
    return [
      for (final r in rows)
        (
          delivery: _delivery(r),
          message: _message({
            ...r,
            'id': r['message_id'],
            'status': r['m_status'],
            'sid': r['m_sid'],
            'counter': r['m_counter'],
          }, null),
        ),
    ];
  }

  Future<void> markDeliverySending(
    cipher.DatabaseExecutor txn,
    String messageId,
    String phone, {
    required int sid,
    required int counter,
    required int parts,
  }) => txn.update(
    'sg_deliveries',
    {
      'status': SecureMessageStatus.sending.name,
      'sid': sid,
      'counter': counter,
      'parts': parts,
    },
    where: 'message_id = ? AND phone = ?',
    whereArgs: [messageId, phone],
  );

  /// Moves a delivery forward, never back (like one-to-one messages).
  Future<bool> advanceDelivery(
    String messageId,
    String phone,
    SecureMessageStatus to,
  ) async {
    final rows = await db.query(
      'sg_deliveries',
      columns: ['status'],
      where: 'message_id = ? AND phone = ?',
      whereArgs: [messageId, phone],
    );
    if (rows.isEmpty) return false;
    final current =
        SecureMessageStatus.values.asNameMap()[rows.first['status']] ??
        SecureMessageStatus.failed;
    const order = [
      SecureMessageStatus.queued,
      SecureMessageStatus.sending,
      SecureMessageStatus.sent,
      SecureMessageStatus.delivered,
      SecureMessageStatus.seen,
    ];
    if (to == SecureMessageStatus.failed) {
      if (order.indexOf(current) >= order.indexOf(SecureMessageStatus.sent)) {
        return false;
      }
    } else if (order.indexOf(to) <= order.indexOf(current)) {
      return false;
    }
    await db.update(
      'sg_deliveries',
      {'status': to.name},
      where: 'message_id = ? AND phone = ?',
      whereArgs: [messageId, phone],
    );
    return true;
  }

  /// Failed deliveries of [messageId] go back to the queue; their phones.
  Future<List<String>> requeueFailed(String messageId) async {
    final rows = await db.query(
      'sg_deliveries',
      columns: ['phone'],
      where: 'message_id = ? AND status = ?',
      whereArgs: [messageId, SecureMessageStatus.failed.name],
    );
    await db.update(
      'sg_deliveries',
      {'status': SecureMessageStatus.queued.name, 'sid': null, 'counter': null},
      where: 'message_id = ? AND status = ?',
      whereArgs: [messageId, SecureMessageStatus.failed.name],
    );
    return [for (final r in rows) r['phone'] as String];
  }

  /// «دیده شد» from [phone]: our deliveries to them in [sid] up to [upTo].
  /// Returns the groups touched.
  Future<Set<String>> markSeenBy(
    cipher.DatabaseExecutor txn,
    String phone,
    int sid,
    int upTo,
  ) async {
    final rows = await txn.rawQuery(
      '''
      SELECT DISTINCT m.group_id FROM sg_deliveries d
        JOIN sg_messages m ON m.id = d.message_id
       WHERE d.phone = ? AND d.sid = ? AND d.counter <= ?
      ''',
      [phone, sid, upTo],
    );
    await txn.rawUpdate(
      '''
      UPDATE sg_deliveries SET status = ?
       WHERE phone = ? AND sid = ? AND counter <= ? AND status IN (?, ?, ?)
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
    return {for (final r in rows) r['group_id'] as String};
  }

  /// «حذف برای هر دو» from [sender]: their group message [counter] of [sid].
  /// Returns the group it was in, if any.
  Future<String?> deleteIncoming(
    cipher.DatabaseExecutor txn,
    String sender,
    int sid,
    int counter,
  ) async {
    final rows = await txn.query(
      'sg_messages',
      columns: ['group_id'],
      where: 'sender = ? AND sid = ? AND counter = ?',
      whereArgs: [sender, sid, counter],
    );
    if (rows.isEmpty) return null;
    await txn.delete(
      'sg_messages',
      where: 'sender = ? AND sid = ? AND counter = ?',
      whereArgs: [sender, sid, counter],
    );
    return rows.first['group_id'] as String;
  }

  Future<void> deleteMessage(String id) => db.transaction((txn) async {
    await txn.delete('sg_deliveries', where: 'message_id = ?', whereArgs: [id]);
    await txn.delete('sg_messages', where: 'id = ?', whereArgs: [id]);
  });

  /// Stamps incoming messages of [groupId] as shown; returns them.
  Future<List<SecureGroupMessage>> markShown(String groupId, int now) =>
      db.transaction((txn) async {
        final rows = await txn.query(
          'sg_messages',
          where: 'group_id = ? AND sender IS NOT NULL AND seen_at IS NULL',
          whereArgs: [groupId],
        );
        await txn.update(
          'sg_messages',
          {'seen_at': now},
          where: 'group_id = ? AND sender IS NOT NULL AND seen_at IS NULL',
          whereArgs: [groupId],
        );
        return [for (final r in rows) _message(r, null)];
      });

  /// Received messages of [groupId], newest counter per sender and session —
  /// what one «دیده شد» per sender covers.
  Future<List<({String sender, int sid, int upTo})>> seenMarks(
    String groupId,
  ) async {
    final rows = await db.rawQuery(
      '''
      SELECT sender, sid, MAX(counter) AS up_to FROM sg_messages
       WHERE group_id = ? AND sender IS NOT NULL AND sid IS NOT NULL
       GROUP BY sender, sid
      ''',
      [groupId],
    );
    return [
      for (final r in rows)
        (
          sender: r['sender'] as String,
          sid: r['sid'] as int,
          upTo: r['up_to'] as int,
        ),
    ];
  }

  Future<int> deleteSeenEphemeral(String groupId) => db.delete(
    'sg_messages',
    where:
        'group_id = ? AND sender IS NOT NULL AND delete_after_seen = 1 '
        'AND seen_at IS NOT NULL',
    whereArgs: [groupId],
  );
}
