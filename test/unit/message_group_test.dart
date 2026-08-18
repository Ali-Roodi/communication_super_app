import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/messages/models/message_group.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/repositories/group_repository.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';

GroupMember _member(String number, [String? name]) =>
    GroupMember(phoneNumber: number, displayName: name);

GroupSendTarget _target(
  String messageId,
  String number, {
  String status = 'sent',
  int? deviceSmsId,
  String? trackingId,
}) => GroupSendTarget(
  messageId: messageId,
  phoneNumber: number,
  status: status,
  deviceSmsId: deviceSmsId,
  trackingId: trackingId,
);

void main() {
  group('GroupThread', () {
    test('a group thread id round-trips and never looks like a number', () {
      final threadId = GroupThread.threadIdFor('abc-123');
      expect(threadId, 'g:abc-123');
      expect(GroupThread.isGroup(threadId), isTrue);
      expect(GroupThread.groupIdOf(threadId), 'abc-123');
      expect(GroupThread.isGroup('09121234567'), isFalse);
      expect(GroupThread.groupIdOf('09121234567'), isNull);
    });
  });

  group('MessageGroup.displayTitle', () {
    final now = DateTime(2026, 1, 1);
    MessageGroup build(List<GroupMember> members, {String? title}) =>
        MessageGroup(
          id: 'g1',
          title: title,
          members: members,
          createdAt: now,
          updatedAt: now,
        );

    test('a named group keeps its name', () {
      final group = build([_member('09120000001', 'علی')], title: 'همکاران');
      expect(group.displayTitle, 'همکاران');
      expect(group.hasTitle, isTrue);
    });

    test('everybody is named while everybody fits, then it counts', () {
      expect(
        build([
          _member('09120000001', 'علی رضایی'),
          _member('09120000002', 'مریم احمدی'),
        ]).displayTitle,
        'علی و مریم',
      );
      // Three is the common case and «و ۱ نفر دیگر» is a worse header than the
      // third name itself.
      expect(
        build([
          _member('09120000001', 'علی رضایی'),
          _member('09120000002', 'مریم احمدی'),
          _member('09120000003', 'رضا'),
        ]).displayTitle,
        'علی، مریم و رضا',
      );
      expect(
        build([
          _member('09120000001', 'علی رضایی'),
          _member('09120000002', 'مریم احمدی'),
          _member('09120000003', 'رضا'),
          _member('09120000004', 'سارا'),
        ]).displayTitle,
        'علی، مریم و ۲ نفر دیگر',
      );
    });

    test('an unsaved member is named by its number, not left blank', () {
      final group = build([
        _member('+989120000001'),
        _member('09120000002', 'مریم'),
      ]);
      expect(group.displayTitle.contains('مریم'), isTrue);
      expect(group.displayTitle.trim(), isNotEmpty);
    });

    test('member keys are canonical, so one person is one member', () {
      final group = build([_member('+989120000001'), _member('09120000001')]);
      expect(group.memberKeys, {'09120000001'});
    });
  });

  group('GroupSendSummary', () {
    test('folds pessimistically — three of four is not «sent»', () {
      final summary = GroupSendSummary.of([
        _target('m1', '09120000001'),
        _target('m1', '09120000002'),
        _target('m1', '09120000003'),
        _target('m1', '09120000004', status: 'failed'),
      ]);
      expect(summary.aggregateStatus, 'failed');
      expect(summary.reached, 3);
      expect(summary.label, 'ارسال شد به ۳ از ۴ نفر');
    });

    test('anything still pending keeps the whole message pending', () {
      final summary = GroupSendSummary.of([
        _target('m1', '09120000001', status: 'delivered'),
        _target('m1', '09120000002', status: 'pending'),
      ]);
      expect(summary.aggregateStatus, 'pending');
    });

    test('delivered only when every recipient is', () {
      expect(
        GroupSendSummary.of([
          _target('m1', '09120000001', status: 'delivered'),
          _target('m1', '09120000002', status: 'delivered'),
        ]).aggregateStatus,
        'delivered',
      );
      expect(
        GroupSendSummary.of([
          _target('m1', '09120000001', status: 'delivered'),
          _target('m1', '09120000002'),
        ]).aggregateStatus,
        'sent',
      );
    });
  });

  group('GroupRepository', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
    });
    setUp(() => DatabaseHelper.resetForTesting());
    tearDownAll(() => DatabaseHelper.resetForTesting());

    test('create deduplicates members on the canonical key', () async {
      final repo = GroupRepository();
      final group = await repo.create(
        members: [
          _member('+989120000001', 'علی'),
          _member('09120000001', 'علی دوباره'),
          _member('09120000002', 'مریم'),
        ],
      );
      expect(group.members.length, 2);
      expect(group.memberKeys, {'09120000001', '09120000002'});
    });

    test('findByMembers matches on the SET, whatever the formatting', () async {
      final repo = GroupRepository();
      final created = await repo.create(
        members: [_member('09120000001'), _member('09120000002')],
      );
      final found = await repo.findByMembers([
        _member('+989120000002'),
        _member('9120000001'),
      ]);
      expect(found?.id, created.id);

      // A different set is a different group — a superset must not match.
      final other = await repo.findByMembers([
        _member('09120000001'),
        _member('09120000002'),
        _member('09120000003'),
      ]);
      expect(other, isNull);
    });

    test('findOrCreate reuses the group instead of making a twin', () async {
      final repo = GroupRepository();
      final first = await repo.findOrCreate(
        members: [_member('09120000001'), _member('09120000002')],
      );
      final second = await repo.findOrCreate(
        members: [_member('09120000002'), _member('09120000001')],
      );
      expect(second.id, first.id);
      expect((await repo.getAll()).length, 1);
    });

    test('findOrCreate names an unnamed group but never renames one', () async {
      final repo = GroupRepository();
      await repo.findOrCreate(
        members: [_member('09120000001'), _member('09120000002')],
      );
      final named = await repo.findOrCreate(
        members: [_member('09120000001'), _member('09120000002')],
        title: 'همکاران',
      );
      expect(named.displayTitle, 'همکاران');

      final again = await repo.findOrCreate(
        members: [_member('09120000001'), _member('09120000002')],
        title: 'چیز دیگری',
      );
      expect(again.displayTitle, 'همکاران');
    });

    test('rename with an empty name restores the derived title', () async {
      final repo = GroupRepository();
      final group = await repo.create(
        members: [
          _member('09120000001', 'علی'),
          _member('09120000002', 'مریم'),
        ],
        title: 'همکاران',
      );
      await repo.rename(group.id, '');
      final fresh = await repo.getById(group.id);
      expect(fresh!.hasTitle, isFalse);
      expect(fresh.displayTitle, 'علی و مریم');
    });

    test('add / remove member', () async {
      final repo = GroupRepository();
      final group = await repo.create(
        members: [_member('09120000001'), _member('09120000002')],
      );
      await repo.addMembers(group.id, [
        _member('09120000003', 'رضا'),
        // Already there — must not duplicate.
        _member('+989120000001'),
      ]);
      expect((await repo.getById(group.id))!.members.length, 3);

      await repo.removeMember(group.id, '09120000002');
      expect((await repo.getById(group.id))!.memberKeys, {
        '09120000001',
        '09120000003',
      });
    });

    test('refreshMemberNames only rewrites the stale rows', () async {
      final repo = GroupRepository();
      final group = await repo.create(
        members: [_member('09120000001', 'علی'), _member('09120000002')],
      );
      final changed = await repo.refreshMemberNames({
        '09120000001': 'علی', // unchanged
        '09120000002': 'مریم', // newly saved contact
      });
      expect(changed, 1);
      final fresh = await repo.getById(group.id);
      final byKey = {for (final m in fresh!.members) m.normalized: m};
      expect(byKey['09120000002']!.displayName, 'مریم');
    });

    test('delete removes the group and its members', () async {
      final repo = GroupRepository();
      final group = await repo.create(
        members: [_member('09120000001'), _member('09120000002')],
      );
      await repo.delete(group.id);
      expect(await repo.getById(group.id), isNull);
      expect(await repo.getAll(), isEmpty);
    });
  });

  group('group send targets vs the mirror-sync', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
    });
    setUp(() => DatabaseHelper.resetForTesting());
    tearDownAll(() => DatabaseHelper.resetForTesting());

    test(
      'every provider row a group send made counts as KNOWN, so the '
      'mirror-sync cannot re-import it into the members\' 1:1 chats',
      () async {
        final groups = GroupRepository();
        final messages = MessageRepository();
        final group = await groups.create(
          members: [_member('09120000001'), _member('09120000002')],
        );
        const messageId = 'gm1';
        await messages.createMessage(
          MessageModel(
            id: messageId,
            threadId: group.threadId,
            phoneNumber: group.threadId,
            body: 'سلام به همه',
            type: MessageType.sent,
            status: MessageStatus.sent,
            timestamp: DateTime(2026, 1, 1, 12),
            isRead: true,
          ),
        );
        await groups.insertTargets([
          _target(messageId, '09120000001', deviceSmsId: 501),
          _target(messageId, '09120000002', deviceSmsId: 502),
        ]);

        final known = await messages.knownDeviceSmsIds([501, 502, 503]);
        expect(known, {501, 502});
      },
    );

    test('a group message survives the stale-row diff', () async {
      final groups = GroupRepository();
      final messages = MessageRepository();
      final group = await groups.create(
        members: [_member('09120000001'), _member('09120000002')],
      );
      await messages.createMessage(
        MessageModel(
          id: 'gm2',
          threadId: group.threadId,
          phoneNumber: group.threadId,
          body: 'سلام',
          type: MessageType.sent,
          status: MessageStatus.sent,
          timestamp: DateTime(2026, 1, 1, 12),
          isRead: true,
        ),
      );
      await groups.insertTargets([
        _target('gm2', '09120000001', deviceSmsId: 601),
      ]);

      // The provider no longer lists 601 — but the group message row itself has
      // no device_sms_id, so it must not be swept away with it.
      final removed = await messages.removeRowsMissingFromDevice({999});
      expect(removed, 0);
      final still = await messages.getMessagesByThread(group.threadId);
      expect(still.length, 1);
    });

    test('applyTargetStatus advances one recipient by tracking id', () async {
      final groups = GroupRepository();
      await groups.insertTargets([
        _target('gm3', '09120000001', status: 'sent', trackingId: 't-1'),
        _target('gm3', '09120000002', status: 'sent', trackingId: 't-2'),
      ]);
      expect(await groups.applyTargetStatus('t-2', 'delivered'), 'gm3');
      // An unknown tracking id is an ordinary 1:1 send, not a group target.
      expect(await groups.applyTargetStatus('t-9', 'delivered'), isNull);

      final targets = await groups.targetsOf('gm3');
      final byKey = {for (final t in targets) t.normalized: t};
      expect(byKey['09120000002']!.status, 'delivered');
      expect(byKey['09120000001']!.status, 'sent');
      expect(
        GroupSendSummary.of(targets).aggregateStatus,
        'sent',
        reason: 'one delivered and one merely sent is «sent», not «delivered»',
      );
    });

    test('a group thread is never a number-search hit', () async {
      final groups = GroupRepository();
      final messages = MessageRepository();
      final group = await groups.create(
        members: [_member('09121111111'), _member('09122222222')],
      );
      await messages.createMessage(
        MessageModel(
          id: 'gm4',
          threadId: group.threadId,
          phoneNumber: group.threadId,
          body: 'یک پیام گروهی',
          type: MessageType.sent,
          status: MessageStatus.sent,
          timestamp: DateTime(2026, 1, 1, 12),
          isRead: true,
        ),
      );
      // A UUID is full of digits; searching for a digit run must not surface the
      // group by accident. (It is found by name/members at the screen level.)
      final digits = RegExp(r'\d{2}').firstMatch(group.id)?.group(0);
      if (digits != null) {
        final hits = await messages.searchThreads(digits);
        expect(hits.any((t) => t.threadId == group.threadId), isFalse);
      }
    });
  });
}
