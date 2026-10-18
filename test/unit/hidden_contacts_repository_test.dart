import 'package:communication_super_app/features/hidden/repositories/hidden_contacts_repository.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

HiddenContact _contact(String id, String name, List<String> phones) =>
    HiddenContact(
      id: id,
      name: name,
      numbers: [for (final p in phones) HiddenNumber(phone: p)],
    );

void main() {
  late Database db;
  late HiddenContactsRepository repo;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SecureStore.createSchemaForTest(db);
    repo = HiddenContactsRepository(database: () => db);
  });

  tearDown(() => db.close());

  test('a locked section is an error, never an empty phonebook', () {
    final locked = HiddenContactsRepository(database: () => null);
    expect(locked.contacts, throwsA(isA<KeyBankLockedException>()));
  });

  test(
    'a contact keeps its numbers in order; saving again replaces them',
    () async {
      await repo.save(
        _contact('a', 'رضا', ['09125555555', '02188776655']),
        100,
      );
      var c = (await repo.contact('a'))!;
      expect(c.numbers.map((n) => n.phone), ['09125555555', '02188776655']);
      expect(c.createdAt, 100);

      await repo.save(_contact('a', 'رضا کریمی', ['09126666666']), 200);
      c = (await repo.contact('a'))!;
      expect(c.name, 'رضا کریمی');
      expect(c.numbers.map((n) => n.phone), ['09126666666']);
      expect(c.createdAt, 100); // created once
      expect(c.updatedAt, 200);
      expect(await repo.allNumbers(), ['09126666666']);
    },
  );

  test('names, owners and deletion', () async {
    await repo.save(_contact('a', 'رضا', ['09125555555']), 1);
    await repo.save(_contact('b', 'مینا', ['09127777777', '09128888888']), 1);
    expect(await repo.names(), {
      '09125555555': 'رضا',
      '09127777777': 'مینا',
      '09128888888': 'مینا',
    });
    expect(await repo.nameFor('09128888888'), 'مینا');
    expect(await repo.nameFor('09120000000'), isNull);
    expect((await repo.ownerOf('09127777777'))!.id, 'b');
    expect(await repo.ownerOf('09127777777', exceptId: 'b'), isNull);
    expect((await repo.contacts()).map((c) => c.name), ['رضا', 'مینا']);

    await repo.delete('b');
    expect(await repo.allNumbers(), ['09125555555']);
    expect(await repo.nameFor('09128888888'), isNull);
  });

  test('a call swept twice is stored once; newest first', () async {
    const call = HiddenCallRecord(
      phone: '09125555555',
      callType: 3,
      timestamp: 1000,
      duration: 0,
    );
    expect(await repo.addCalls([call, call]), 1);
    expect(await repo.addCalls([call]), 0);
    await repo.addCalls([
      const HiddenCallRecord(
        phone: '09127777777',
        callType: 2,
        timestamp: 2000,
        duration: 65,
        account: '89980',
      ),
    ]);
    final calls = await repo.calls();
    expect(calls.map((c) => c.timestamp), [2000, 1000]);
    expect(calls.first.account, '89980');
    expect((await repo.calls(phones: ['09125555555'])).single.callType, 3);
    await repo.deleteCalls([calls.first.id]);
    expect(await repo.calls(), hasLength(1));
    await repo.clearCalls();
    expect(await repo.calls(), isEmpty);
  });
}
