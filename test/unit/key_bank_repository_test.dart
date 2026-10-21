import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List _b(int n, int fill) => Uint8List(n)..fillRange(0, n, fill);

OpenedKeyFile _file({
  int kid = 1,
  String phone = '09121111111',
  int generation = 0,
  int authority = 0xAA,
}) => OpenedKeyFile(
  authorityId: _b(8, authority),
  secret: _b(97, 0x50 + kid),
  cert: MemberCertInfo(
    cert: _b(103, 0x30 + kid),
    keyId: _b(8, kid),
    phone: phone,
    generation: generation,
  ),
);

void main() {
  late Database db;
  late KeyBankRepository repo;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SecureStore.createSchemaForTest(db);
    repo = KeyBankRepository(database: () => db);
  });

  tearDown(() => db.close());

  test('a locked section is an error, never an empty bank', () async {
    final locked = KeyBankRepository(database: () => null);
    expect(locked.snapshot, throwsA(isA<KeyBankLockedException>()));
    expect(locked.ownKeys, throwsA(isA<KeyBankLockedException>()));
  });

  test(
    'a key file stores the own key and its certificate — nothing else',
    () async {
      expect(
        await repo.importKeyFile(_file(), now: DateTime(2026, 10, 21)),
        KeyImportOutcome.added,
      );
      final key = (await repo.snapshot()).keys.single;
      expect(key.keyId, '0101010101010101');
      expect(key.authorityId, 'aaaaaaaaaaaaaaaa');
      expect(key.phone, '09121111111');
      expect(key.generation, 0);
      expect(key.importedAt, DateTime(2026, 10, 21).millisecondsSinceEpoch);
      final own = (await repo.ownKeys()).single;
      expect(own.secret, _b(97, 0x51));
      expect(own.cert, _b(103, 0x31));
      // There is no table of anybody else.
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'kb_%'",
      );
      expect([for (final t in tables) t['name']], ['kb_own_keys']);
    },
  );

  test('the same file twice is already imported', () async {
    await repo.importKeyFile(_file());
    expect(await repo.importKeyFile(_file()), KeyImportOutcome.alreadyImported);
    expect((await repo.ownKeys()), hasLength(1));
  });

  test('a new generation from the same authority replaces the key', () async {
    await repo.importKeyFile(_file(kid: 1, generation: 0));
    expect(
      await repo.importKeyFile(_file(kid: 2, generation: 1)),
      KeyImportOutcome.replaced,
    );
    final own = (await repo.ownKeys()).single;
    expect(own.keyId, '0202020202020202');
    // …and going back to the old generation is refused.
    expect(
      await repo.importKeyFile(_file(kid: 1, generation: 0)),
      KeyImportOutcome.older,
    );
    expect((await repo.ownKeys()).single.keyId, '0202020202020202');
  });

  test(
    'a key for another number from the same authority replaces it',
    () async {
      await repo.importKeyFile(
        _file(kid: 1, phone: '09121111111', generation: 3),
      );
      expect(
        await repo.importKeyFile(_file(kid: 2, phone: '09122222222')),
        KeyImportOutcome.replaced,
      );
      expect((await repo.snapshot()).keys.single.phone, '09122222222');
    },
  );

  test('keys of two authorities live side by side', () async {
    await repo.importKeyFile(_file(kid: 1, authority: 0xAA));
    expect(
      await repo.importKeyFile(_file(kid: 2, authority: 0xBB)),
      KeyImportOutcome.added,
    );
    expect(await repo.ownKeys(), hasLength(2));
  });

  test('removing a key leaves nothing behind', () async {
    await repo.importKeyFile(_file());
    await repo.removeKey('0101010101010101');
    expect((await repo.snapshot()).isEmpty, isTrue);
    expect(await repo.ownKeys(), isEmpty);
  });
}
