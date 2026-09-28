import 'dart:io';

import 'package:communication_super_app/features/secure/repositories/secure_group_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SecureGroupStore groups;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SecureStore.createSchemaForTest(db);
    groups = SecureGroupStore(database: () => db);
  });

  tearDown(() => db.close());

  const a = (phone: '09121111111', keyId: 'aa');
  const b = (phone: '09122222222', keyId: 'bb');

  test(
    'who a message goes to depends on the mode and on whose group it is',
    () {
      const members = [
        SecureGroupMember(phone: '09121111111', keyId: 'aa'),
        SecureGroupMember(phone: '09122222222', keyId: 'bb'),
      ];
      SecureGroup g(SecureGroupMode mode, String? creator) => SecureGroup(
        id: 'g',
        name: 'n',
        mode: mode,
        version: 1,
        creator: creator,
        createdAt: 0,
        lastAt: 0,
        members: members,
      );
      expect(g(SecureGroupMode.chat, null).recipients, [a.phone, b.phone]);
      expect(g(SecureGroupMode.chat, '09123333333').recipients, [
        '09123333333',
        a.phone,
        b.phone,
      ]);
      expect(g(SecureGroupMode.announce, null).recipients, [a.phone, b.phone]);
      expect(g(SecureGroupMode.announce, '09123333333').recipients, [
        '09123333333',
      ]);
    },
  );

  test('a definition applies only when newer and from the creator', () async {
    Future<bool> apply(String sender, int version, String name) =>
        db.transaction(
          (txn) => groups.applyInfo(
            txn,
            id: 'g1',
            sender: sender,
            version: version,
            mode: SecureGroupMode.chat,
            name: name,
            members: [a],
            includesMe: true,
            now: 1,
          ),
        );
    expect(await apply('09129999999', 1, 'اول'), isTrue);
    expect(await apply('09129999999', 1, 'تکراری'), isFalse); // not newer
    expect(await apply('09128888888', 5, 'جعلی'), isFalse); // not the creator
    expect(await apply('09129999999', 2, 'دوم'), isTrue);
    final g = (await groups.group('g1'))!;
    expect(g.name, 'دوم');
    expect(g.creator, '09129999999');
  });

  test('a placeholder takes its creator from the first definition', () async {
    await db.transaction((txn) => groups.ensurePlaceholder(txn, 'g2', 5));
    expect((await groups.group('g2'))!.pendingInfo, isTrue);
    await db.transaction(
      (txn) => groups.applyInfo(
        txn,
        id: 'g2',
        sender: '09127777777',
        version: 1,
        mode: SecureGroupMode.announce,
        name: 'اطلاعیه',
        members: [a, b],
        includesMe: false,
        now: 6,
      ),
    );
    final g = (await groups.group('g2'))!;
    expect(g.pendingInfo, isFalse);
    expect(g.creator, '09127777777');
    expect(g.left, isTrue); // the definition does not list this phone
    expect(g.members, hasLength(2));
  });

  test('an edit keeps a dropped member until told, then drops them', () async {
    await groups.createGroup(
      id: 'g3',
      name: 'تیم',
      mode: SecureGroupMode.chat,
      members: [a, b],
      now: 1,
    );
    await groups.editGroup(id: 'g3', name: 'تیم ۲', members: [a]);
    var g = (await groups.group('g3'))!;
    expect(g.version, 2);
    expect(g.members.map((m) => m.phone), [a.phone]);
    expect(await groups.allMembers('g3'), hasLength(2));
    expect((await groups.staleInfoFor(b.phone)).map((g) => g.id), ['g3']);

    await groups.markInfoSent('g3', b.phone, 2);
    expect(await groups.allMembers('g3'), hasLength(1));
    await groups.markInfoSent('g3', a.phone, 2);
    expect(await groups.staleInfoFor(a.phone), isEmpty);
    g = (await groups.group('g3'))!;
    expect(g.name, 'تیم ۲');
  });

  test(
    'a phase G section (v4) gains groups; its conversations stay listed',
    () async {
      final dir = await Directory.systemTemp.createTemp('group_migration');
      final old = await databaseFactoryFfi.openDatabase('${dir.path}/v4.db');
      await old.execute(
        'CREATE TABLE secure_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await SecureStore.upgradeSchemaForTest(old, 1, to: 4);
      await old.insert('sm_conversations', {
        'phone': '09122222222',
        'name': 'سارا',
        'peer_key_id': 'aa',
        'peer_public': Uint8List(4),
        'own_key_id': 'bb',
        'own_source': 'directory:d',
        'created_at': 1,
        'last_at': 5,
      });
      await SecureStore.upgradeSchemaForTest(old, 4);

      final store = SecureMessageStore(database: () => old);
      expect((await store.conversations()).single.name, 'سارا');
      await SecureGroupStore(database: () => old).createGroup(
        id: 'g',
        name: 'گروه',
        mode: SecureGroupMode.chat,
        members: [a],
        now: 1,
      );
      expect(
        await SecureGroupStore(database: () => old).groups(),
        hasLength(1),
      );
      await old.close();
      await dir.delete(recursive: true);
    },
  );
}
