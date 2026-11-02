import 'package:communication_super_app/features/hidden/repositories/hidden_contacts_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_group_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The newest-N windows the long secure lists page through: the newest rows,
/// still oldest first, and nothing past the window.
void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SecureStore.createSchemaForTest(db);
  });

  tearDown(() => db.close());

  test('a conversation window is its newest messages, oldest first', () async {
    for (var i = 0; i < 120; i++) {
      await db.insert('sm_messages', {
        'id': 'm$i',
        'phone': '09121111111',
        'outgoing': i.isEven ? 1 : 0,
        'body': 'b$i',
        'timestamp': 1000 + i,
        'status': 'sent',
      });
    }
    await db.insert('sm_messages', {
      'id': 'other',
      'phone': '09122222222',
      'outgoing': 0,
      'body': 'x',
      'timestamp': 5000,
      'status': 'sent',
    });
    final store = SecureMessageStore(database: () => db);

    final all = await store.messages('09121111111');
    expect(all, hasLength(120));
    expect(all.first.id, 'm0');

    final window = await store.messages('09121111111', limit: 51);
    expect(window, hasLength(51));
    expect(window.first.id, 'm69');
    expect(window.last.id, 'm119');

    final short = await store.messages('09122222222', limit: 51);
    expect(short.map((m) => m.id), ['other']);
  });

  test('a group window is its newest messages, oldest first', () async {
    for (var i = 0; i < 80; i++) {
      await db.insert('sg_messages', {
        'id': 'g$i',
        'group_id': 'grp',
        'sender': i.isEven ? null : '09121111111',
        'body': 'b$i',
        'timestamp': 1000 + i,
        'status': 'sent',
      });
    }
    final groups = SecureGroupStore(database: () => db);
    final window = await groups.messages('grp', limit: 51);
    expect(window, hasLength(51));
    expect(window.first.id, 'g29');
    expect(window.last.id, 'g79');
    expect(await groups.messages('grp'), hasLength(80));
  });

  test('hidden calls take a limit, newest first', () async {
    final repo = HiddenContactsRepository(database: () => db);
    await repo.addCalls([
      for (var i = 0; i < 70; i++)
        HiddenCallRecord(
          phone: i.isEven ? '09125555555' : '09127777777',
          callType: 1,
          timestamp: 1000 + i,
          duration: 0,
        ),
    ]);
    final page = await repo.calls(limit: 51);
    expect(page, hasLength(51));
    expect(page.first.timestamp, 1069);
    final mine = await repo.calls(phones: ['09125555555'], limit: 10);
    expect(mine, hasLength(10));
    expect(mine.every((c) => c.phone == '09125555555'), isTrue);
    expect(mine.first.timestamp, 1068);
  });
}
