import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/database/database_helper.dart';
import '../models/message_group.dart';

/// Storage for «پیام گروهی» — the local group conversations and the per-recipient
/// record of what each group message actually sent.
///
/// Nothing here touches the SMS provider: a group is an app-side construct (see
/// `DatabaseHelper._createMessageGroupTables`), and the real SMS are ordinary
/// sends made by `SmsService`.
class GroupRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  // ── Groups ────────────────────────────────────────────────────────────────

  /// Creates a group and returns it.
  ///
  /// Members are deduplicated on the canonical key, so «+98912…» and «0912…»
  /// picked from two different screens are one person.
  Future<MessageGroup> create({
    required List<GroupMember> members,
    String? title,
  }) async {
    final db = await _dbHelper.database;
    final now = DateTime.now();
    final id = const Uuid().v4();
    final unique = _dedupe(members);

    await db.transaction((txn) async {
      await txn.insert(AppConstants.messageGroupsTable, {
        'id': id,
        'title': (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : null,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
      final batch = txn.batch();
      for (final member in unique) {
        batch.insert(
          AppConstants.messageGroupMembersTable,
          member.toRow(id, addedAt: now),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });

    return MessageGroup(
      id: id,
      title: (title != null && title.trim().isNotEmpty) ? title.trim() : null,
      members: unique,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// The group with the **same set of members** as [members], or null.
  ///
  /// Picking the same three people twice must land in the conversation that
  /// already exists rather than starting an identical second one — that is how
  /// Google Messages keys a group, and without it the inbox fills with
  /// indistinguishable rows.
  ///
  /// Compared in Dart over the member table (one row per member per group, so a
  /// handful of rows on any real phone): the comparison is set equality, which
  /// SQL cannot express without a per-group count join that would be longer than
  /// this and no faster.
  Future<MessageGroup?> findByMembers(Iterable<GroupMember> members) async {
    final wanted = {for (final m in _dedupe(members.toList())) m.normalized};
    if (wanted.isEmpty) return null;
    final groups = await getAll();
    for (final group in groups) {
      if (group.memberKeys.length == wanted.length &&
          group.memberKeys.containsAll(wanted)) {
        return group;
      }
    }
    return null;
  }

  /// The existing group for [members], or a new one.
  Future<MessageGroup> findOrCreate({
    required List<GroupMember> members,
    String? title,
  }) async {
    final existing = await findByMembers(members);
    if (existing != null) {
      // A title supplied now (opening a label as a group) names a group that
      // never had one; it never overwrites a name the user chose.
      if (!existing.hasTitle && title != null && title.trim().isNotEmpty) {
        await rename(existing.id, title);
        return existing.copyWith(title: title.trim());
      }
      return existing;
    }
    return create(members: members, title: title);
  }

  /// Every group, with its members, newest activity first.
  ///
  /// One query per table rather than a join: the member rows are assembled in
  /// Dart, so a group with three members is three rows and not three copies of
  /// the group row.
  Future<List<MessageGroup>> getAll() async {
    final db = await _dbHelper.database;
    final groupRows = await db.query(
      AppConstants.messageGroupsTable,
      orderBy: 'updated_at DESC',
    );
    if (groupRows.isEmpty) return const [];
    final memberRows = await db.query(
      AppConstants.messageGroupMembersTable,
      orderBy: 'added_at ASC',
    );
    final byGroup = <String, List<GroupMember>>{};
    for (final row in memberRows) {
      byGroup
          .putIfAbsent(row['group_id'] as String, () => [])
          .add(GroupMember.fromRow(row));
    }
    return [
      for (final row in groupRows)
        MessageGroup(
          id: row['id'] as String,
          title: row['title'] as String?,
          members: byGroup[row['id'] as String] ?? const [],
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at'] as int,
          ),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            row['updated_at'] as int,
          ),
        ),
    ];
  }

  /// Every group keyed by its **thread id**, which is what the inbox rows carry.
  Future<Map<String, MessageGroup>> getAllByThreadId() async {
    final groups = await getAll();
    return {for (final g in groups) g.threadId: g};
  }

  Future<MessageGroup?> getById(String groupId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.messageGroupsTable,
      where: 'id = ?',
      whereArgs: [groupId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final memberRows = await db.query(
      AppConstants.messageGroupMembersTable,
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'added_at ASC',
    );
    final row = rows.first;
    return MessageGroup(
      id: groupId,
      title: row['title'] as String?,
      members: [for (final m in memberRows) GroupMember.fromRow(m)],
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  /// The group behind a thread id, or null when the id is a phone number.
  Future<MessageGroup?> getByThreadId(String threadId) async {
    final id = GroupThread.groupIdOf(threadId);
    if (id == null) return null;
    return getById(id);
  }

  /// Renames a group. An empty name clears the title, so the derived
  /// «علی، مریم و ۲ نفر دیگر» comes back.
  Future<void> rename(String groupId, String? title) async {
    final db = await _dbHelper.database;
    final trimmed = title?.trim();
    await db.update(
      AppConstants.messageGroupsTable,
      {
        'title': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  Future<void> addMembers(String groupId, List<GroupMember> members) async {
    if (members.isEmpty) return;
    final db = await _dbHelper.database;
    final now = DateTime.now();
    final batch = db.batch();
    for (final member in _dedupe(members)) {
      batch.insert(
        AppConstants.messageGroupMembersTable,
        member.toRow(groupId, addedAt: now),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    batch.update(
      AppConstants.messageGroupsTable,
      {'updated_at': now.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [groupId],
    );
    await batch.commit(noResult: true);
  }

  Future<void> removeMember(String groupId, String normalized) async {
    final db = await _dbHelper.database;
    await db.delete(
      AppConstants.messageGroupMembersTable,
      where: 'group_id = ? AND normalized = ?',
      whereArgs: [groupId, normalized],
    );
    await db.update(
      AppConstants.messageGroupsTable,
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  /// Refreshes the denormalized member names from a fresh
  /// (normalized number → contact name) index.
  ///
  /// The name is stored so a group can be titled without reading the address
  /// book; this is what keeps that copy from going stale after a rename. Only
  /// rows whose name actually changed are written.
  Future<int> refreshMemberNames(Map<String, String> nameByNormalized) async {
    if (nameByNormalized.isEmpty) return 0;
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.messageGroupMembersTable,
      columns: ['group_id', 'normalized', 'display_name'],
    );
    final stale = [
      for (final row in rows)
        if (nameByNormalized[row['normalized'] as String] case final name?)
          if (name != row['display_name']) (row, name),
    ];
    if (stale.isEmpty) return 0;
    final batch = db.batch();
    for (final (row, name) in stale) {
      batch.update(
        AppConstants.messageGroupMembersTable,
        {'display_name': name},
        where: 'group_id = ? AND normalized = ?',
        whereArgs: [row['group_id'], row['normalized']],
      );
    }
    await batch.commit(noResult: true);
    return stale.length;
  }

  /// Deletes the group and its members.
  ///
  /// The **messages** are not touched here — the caller soft-deletes them (see
  /// `SmsService.deleteThreadGlobally`), because their `message_group_targets`
  /// rows are the tombstones that stop the mirror-sync re-importing the SMS the
  /// group sent.
  Future<void> delete(String groupId) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      await txn.delete(
        AppConstants.messageGroupMembersTable,
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
      await txn.delete(
        AppConstants.messageGroupsTable,
        where: 'id = ?',
        whereArgs: [groupId],
      );
    });
  }

  /// Bumps a group's `updated_at`, so «آخرین فعالیت» ordering of the details
  /// list follows the conversation.
  Future<void> touch(String groupId) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messageGroupsTable,
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  // ── Send targets ──────────────────────────────────────────────────────────

  Future<void> insertTargets(List<GroupSendTarget> targets) async {
    if (targets.isEmpty) return;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final target in targets) {
      batch.insert(
        AppConstants.messageGroupTargetsTable,
        target.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateTarget(GroupSendTarget target) async {
    final db = await _dbHelper.database;
    await db.update(
      AppConstants.messageGroupTargetsTable,
      target.toRow(),
      where: 'message_id = ? AND normalized = ?',
      whereArgs: [target.messageId, target.normalized],
    );
  }

  /// Advances one recipient's status, addressed by the tracking id the native
  /// send was given. Returns the message id the recipient belongs to, or null
  /// when the tracking id is not a group target (an ordinary 1:1 send).
  Future<String?> applyTargetStatus(String trackingId, String status) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.messageGroupTargetsTable,
      columns: ['message_id'],
      where: 'tracking_id = ?',
      whereArgs: [trackingId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    await db.update(
      AppConstants.messageGroupTargetsTable,
      {'status': status},
      where: 'tracking_id = ?',
      whereArgs: [trackingId],
    );
    return rows.first['message_id'] as String;
  }

  Future<List<GroupSendTarget>> targetsOf(String messageId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      AppConstants.messageGroupTargetsTable,
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    return [for (final row in rows) GroupSendTarget.fromRow(row)];
  }

  /// Targets for several messages at once, keyed by message id — what the
  /// conversation needs to draw a screenful of aggregate ticks without a query
  /// per bubble.
  Future<Map<String, List<GroupSendTarget>>> targetsForMessages(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return const {};
    final db = await _dbHelper.database;
    final byMessage = <String, List<GroupSendTarget>>{};
    // Chunked to stay well under SQLite's bound-variable limit on a long thread.
    for (var i = 0; i < messageIds.length; i += 400) {
      final end = i + 400 > messageIds.length ? messageIds.length : i + 400;
      final chunk = messageIds.sublist(i, end);
      final rows = await db.query(
        AppConstants.messageGroupTargetsTable,
        where: 'message_id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      for (final row in rows) {
        byMessage
            .putIfAbsent(row['message_id'] as String, () => [])
            .add(GroupSendTarget.fromRow(row));
      }
    }
    return byMessage;
  }

  /// Every provider row id a group send ever produced for the messages of
  /// [threadId] — the specs a global delete has to remove.
  Future<List<int>> deviceSmsIdsForThread(String threadId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT t.device_sms_id AS id
      FROM ${AppConstants.messageGroupTargetsTable} t
      JOIN ${AppConstants.messagesTable} m ON m.id = t.message_id
      WHERE m.thread_id = ? AND t.device_sms_id IS NOT NULL
      ''',
      [threadId],
    );
    return [for (final row in rows) (row['id'] as num).toInt()];
  }

  static List<GroupMember> _dedupe(List<GroupMember> members) {
    final seen = <String>{};
    final out = <GroupMember>[];
    for (final member in members) {
      final key = member.normalized;
      if (key.isEmpty || !seen.add(key)) continue;
      out.add(member);
    }
    return out;
  }
}
