import 'dart:io';

import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List _b(int n, int fill) => Uint8List(n)..fillRange(0, n, fill);

DirectoryMember _member(String name, List<String> phones, int kid) =>
    DirectoryMember(
      name: name,
      phones: phones,
      publicKey: _b(1217, kid),
      keyId: _b(8, kid),
    );

OpenedKeyFile _file({
  int serial = 100,
  List<DirectoryMember>? members,
  int? ownIndex,
  int directory = 1,
}) {
  final list =
      members ??
      [
        _member('علی', ['09121111111', '02188776655'], 1),
        _member('مریم', ['09122222222'], 2),
      ];
  return OpenedKeyFile(
    signed: _b(40, serial % 256),
    directory: KeyDirectory(
      authorityId: _b(8, 0xAA),
      directoryId: _b(8, directory),
      serial: serial,
      name: 'سازمان $directory',
      members: list,
    ),
    memberIndex: ownIndex,
    member: ownIndex == null
        ? null
        : SmsIdentity(
            secret: _b(97, 0x50 + ownIndex),
            publicKey: list[ownIndex].publicKey,
            keyId: list[ownIndex].keyId,
          ),
  );
}

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
  });

  test('importing a key file stores the directory and the own key', () async {
    expect(
      await repo.importKeyFile(_file(ownIndex: 1)),
      KeyImportOutcome.added,
    );
    final s = await repo.snapshot();
    expect(s.directories, hasLength(1));
    final d = s.directories.single;
    expect(d.name, 'سازمان 1');
    expect(d.memberCount, 2);
    expect(d.ownName, 'مریم');
    expect(d.id, '0101010101010101');
    expect(d.authorityId, 'aaaaaaaaaaaaaaaa');

    final keys = await repo.directoryKeysFor('02188776655');
    expect(keys.single.name, 'علی');
    expect(keys.single.keyId, _b(8, 1));
    expect(keys.single.source, 'directory:0101010101010101');
    expect(await repo.directoryKeysFor('09129999999'), isEmpty);
    expect((await repo.ownDirectoryKeys()).single.secret, _b(97, 0x51));
  });

  test('the same file twice changes nothing; a personal file after the '
      'directory-only one adds the key', () async {
    expect(await repo.importKeyFile(_file()), KeyImportOutcome.added);
    expect(await repo.importKeyFile(_file()), KeyImportOutcome.alreadyImported);
    expect(
      await repo.importKeyFile(_file(ownIndex: 0)),
      KeyImportOutcome.ownKeyAdded,
    );
    expect(
      await repo.importKeyFile(_file(ownIndex: 0)),
      KeyImportOutcome.alreadyImported,
    );
    expect((await repo.snapshot()).directories.single.ownName, 'علی');
  });

  test(
    'a newer directory replaces the members; an older one is refused',
    () async {
      await repo.importKeyFile(_file(serial: 100, ownIndex: 0));
      final newer = [
        _member('علی', ['09121111111'], 1),
        _member('سارا', ['09123333333'], 3),
      ];
      expect(
        await repo.importKeyFile(_file(serial: 200, members: newer)),
        KeyImportOutcome.updated,
      );
      expect(await repo.directoryKeysFor('09122222222'), isEmpty); // removed
      expect(
        await repo.directoryKeysFor('02188776655'),
        isEmpty,
      ); // number dropped
      expect((await repo.directoryKeysFor('09123333333')).single.name, 'سارا');
      // Still listed, so the own key stays.
      expect((await repo.snapshot()).directories.single.ownName, 'علی');

      expect(
        await repo.importKeyFile(_file(serial: 150, ownIndex: 1)),
        KeyImportOutcome.older,
      );
      expect((await repo.snapshot()).directories.single.serial, 200);
    },
  );

  test('a newer directory that no longer lists our key drops it', () async {
    await repo.importKeyFile(_file(serial: 100, ownIndex: 1)); // مریم
    final rotated = [
      _member('علی', ['09121111111'], 1),
      _member('مریم', ['09122222222'], 9), // new generation, new key
    ];
    await repo.importKeyFile(_file(serial: 300, members: rotated));
    expect((await repo.snapshot()).directories.single.hasOwnKey, isFalse);
    expect(await repo.ownDirectoryKeys(), isEmpty);
  });

  test(
    'removing a directory removes its members, numbers and own key',
    () async {
      await repo.importKeyFile(_file(ownIndex: 0));
      await repo.importKeyFile(_file(directory: 2));
      await repo.removeDirectory('0101010101010101');
      final s = await repo.snapshot();
      expect(s.directories.map((d) => d.name), ['سازمان 2']);
      expect(await repo.ownDirectoryKeys(), isEmpty);
      for (final table in ['kb_members', 'kb_member_phones']) {
        final rows = await db.query(
          table,
          where: 'directory_id = ?',
          whereArgs: ['0101010101010101'],
        );
        expect(rows, isEmpty, reason: table);
      }
    },
  );

  test('groups and own numbers', () async {
    expect(
      await repo.addGroup(groupId: _b(8, 7), name: ' گروه ', seed: _b(33, 1)),
      isTrue,
    );
    expect(
      await repo.addGroup(groupId: _b(8, 7), name: 'دوباره', seed: _b(33, 1)),
      isFalse,
    );
    expect(await repo.addOwnNumber('09121111111'), isTrue);
    expect(await repo.addOwnNumber('09121111111'), isFalse);
    var s = await repo.snapshot();
    expect(s.groups.single.name, 'گروه');
    expect(s.groups.single.id, '0707070707070707');
    expect(s.ownNumbers, ['09121111111']);
    expect((await repo.groupSeeds()).single.seed, _b(33, 1));

    await repo.removeGroup('0707070707070707');
    await repo.removeOwnNumber('09121111111');
    s = await repo.snapshot();
    expect(s.groups, isEmpty);
    expect(s.ownNumbers, isEmpty);
  });

  test('a phase C section (schema v1) gains the key bank tables', () async {
    // A file of its own: the in-memory database is shared with setUp's.
    final dir = await Directory.systemTemp.createTemp('kb_migration');
    final old = await databaseFactoryFfi.openDatabase(
      '${dir.path}/secure_v1.db',
    );
    await old.execute(
      'CREATE TABLE secure_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await SecureStore.upgradeSchemaForTest(old, 1);
    final upgraded = KeyBankRepository(database: () => old);
    expect(await upgraded.importKeyFile(_file()), KeyImportOutcome.added);
    await old.close();
    await dir.delete(recursive: true);
  });
}
