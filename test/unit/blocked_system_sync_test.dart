import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';
import 'package:communication_super_app/features/settings/services/system_block_list.dart';

/// The phone's own blocked list, in memory. Matches like the platform does:
/// an unblock by any spelling of a number takes it off.
class _FakeSystemList implements SystemBlockList {
  bool writable = true;
  final List<String> numbers = [];

  Set<String> get keys => {
    for (final n in numbers) BlockedNumberModel.normalize(n),
  };

  @override
  Future<bool> available() async => writable;

  @override
  Future<List<String>> list() async => writable ? List.of(numbers) : const [];

  @override
  Future<List<String>> add(List<String> wanted) async {
    if (!writable) return const [];
    for (final n in wanted) {
      if (!keys.contains(BlockedNumberModel.normalize(n))) numbers.add(n);
    }
    return wanted;
  }

  @override
  Future<bool> remove(List<String> gone) async {
    if (!writable) return false;
    final goneKeys = {for (final n in gone) BlockedNumberModel.normalize(n)};
    numbers.removeWhere(
      (n) => goneKeys.contains(BlockedNumberModel.normalize(n)),
    );
    return true;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
  });

  late _FakeSystemList system;
  late BlockedNumbersRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.resetForTesting();
    system = _FakeSystemList();
    repo = BlockedNumbersRepository(system: system);
  });
  tearDownAll(() => DatabaseHelper.resetForTesting());

  Future<Set<String>> local() => repo.blockedKeys();

  test('a block is written to the phone list too', () async {
    await repo.block('+98 912 111 2233', report: true);
    expect(system.keys, {'09121112233'});
    // Nothing for a sync to undo or repeat.
    expect(await repo.syncWithSystem(), isFalse);
    expect(await local(), {'09121112233'});
    expect(system.numbers, hasLength(1));
  });

  test('unblockAll takes a large selection off both lists', () async {
    // More than one 400-key query chunk — the «انتخاب همه» case.
    final numbers = [
      for (var i = 0; i < 450; i++) '0912${(1000000 + i).toString()}',
    ];
    for (final n in numbers) {
      await repo.block(n);
    }
    expect(system.numbers, hasLength(450));

    await repo.unblockAll(numbers.take(449));
    expect(await local(), {numbers.last});
    expect(system.keys, {numbers.last});
    expect(await repo.syncWithSystem(), isFalse);
    expect(await local(), {numbers.last});
  });

  test('a number blocked in another app is brought in', () async {
    await repo.syncWithSystem();
    system.numbers.add('+989121112233');

    expect(await repo.syncWithSystem(), isTrue);
    final row = (await repo.getBlocked()).single;
    expect(row.normalized, '09121112233');
    expect(row.isSpam, isFalse);
  });

  test('a number unblocked in another app is unblocked here', () async {
    await repo.block('09121112233');
    await repo.block('09120000000');
    system.numbers.removeWhere(
      (n) => BlockedNumberModel.normalize(n) == '09121112233',
    );

    expect(await repo.syncWithSystem(), isTrue);
    expect(await local(), {'09120000000'});
    // And it is not written back.
    expect(system.keys, {'09120000000'});
  });

  test('one blocked and one unblocked elsewhere in the same gap', () async {
    await repo.block('09121112233');
    system.numbers
      ..clear()
      ..add('09120000000');

    expect(await repo.syncWithSystem(), isTrue);
    expect(await local(), {'09120000000'});
  });

  test('the first sync pushes the blocks the app already had', () async {
    system.writable = false;
    await repo.block('09121112233');
    await repo.block('09120000000');
    expect(system.numbers, isEmpty);

    system.writable = true;
    expect(await repo.syncWithSystem(), isFalse);
    expect(system.keys, {'09121112233', '09120000000'});
    expect(await local(), {'09121112233', '09120000000'});
  });

  test('a phone-list entry the app had never seen is kept on both', () async {
    // What a phone holds before the app is ever the default: imported, not
    // treated as "unblocked here".
    system.numbers.addAll(['09121112233', '+989120000000']);
    await repo.block('09125555555');

    expect(await repo.syncWithSystem(), isTrue);
    expect(await local(), {'09121112233', '09120000000', '09125555555'});
    expect(system.keys, {'09121112233', '09120000000', '09125555555'});
  });

  test(
    'an unblock made while the list was unwritable reaches it later',
    () async {
      await repo.block('09121112233');
      await repo.block('09120000000');

      system.writable = false;
      await repo.unblock('09121112233');
      expect(await local(), {'09120000000'});

      system.writable = true;
      // Not read as "blocked in another app" — it is taken off the phone list.
      expect(await repo.syncWithSystem(), isFalse);
      expect(await local(), {'09120000000'});
      expect(system.keys, {'09120000000'});

      // And blocking it again in the phone's app afterwards is honoured.
      system.numbers.add('09121112233');
      expect(await repo.syncWithSystem(), isTrue);
      expect(await local(), {'09121112233', '09120000000'});
    },
  );

  test(
    're-blocking in the app after a pending unblock keeps it blocked',
    () async {
      await repo.block('09121112233');
      system.writable = false;
      await repo.unblock('09121112233');
      await repo.block('09121112233');

      system.writable = true;
      await repo.syncWithSystem();
      expect(await local(), {'09121112233'});
      expect(system.keys, {'09121112233'});
    },
  );

  test('without the list nothing changes and nothing throws', () async {
    system.writable = false;
    await repo.block('09121112233');
    expect(await repo.syncWithSystem(), isFalse);
    expect(await local(), {'09121112233'});
  });
}
