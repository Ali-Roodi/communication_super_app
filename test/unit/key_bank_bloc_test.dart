import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/features/keybank/bloc/key_bank_bloc.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MockSession extends MockBloc<SecureSessionEvent, SecureSessionState>
    implements SecureSessionBloc {}

class _MockCrypto extends Mock implements SmsCryptoService {}

Uint8List _b(int n, int fill) => Uint8List(n)..fillRange(0, n, fill);

OpenedKeyFile _opened() => OpenedKeyFile(
  signed: _b(40, 1),
  directory: KeyDirectory(
    authorityId: _b(8, 0xAA),
    directoryId: _b(8, 1),
    serial: 100,
    name: 'سازمان',
    members: [
      DirectoryMember(
        name: 'علی',
        phones: const ['09121111111'],
        publicKey: _b(1217, 1),
        keyId: _b(8, 1),
      ),
    ],
  ),
  memberIndex: 0,
  member: SmsIdentity(
    secret: _b(97, 9),
    publicKey: _b(1217, 1),
    keyId: _b(8, 1),
  ),
);

void main() {
  late Database db;
  late bool open;
  late _MockSession session;
  late StreamController<SecureSessionState> sessionStates;
  late _MockCrypto crypto;

  setUpAll(() {
    sqfliteFfiInit();
    registerFallbackValue(Uint8List(0));
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SecureStore.createSchemaForTest(db);
    open = true;
    session = _MockSession();
    sessionStates = StreamController<SecureSessionState>.broadcast();
    whenListen(
      session,
      sessionStates.stream,
      initialState: const SecureSessionState(status: SecureStatus.unlocked),
    );
    crypto = _MockCrypto();
  });

  tearDown(() async {
    await sessionStates.close();
    await db.close();
  });

  KeyBankBloc build() => KeyBankBloc(
    session: session,
    repository: KeyBankRepository(database: () => open ? db : null),
    crypto: crypto,
    anchors: () => [_b(1985, 1)],
  );

  Future<KeyBankState> settle(
    KeyBankBloc bloc,
    bool Function(KeyBankState) until,
  ) => bloc.stream.firstWhere(until).timeout(const Duration(seconds: 5));

  test('an open section loads the bank; locking empties it', () async {
    final bloc = build();
    final ready = await settle(bloc, (s) => s.status == KeyBankStatus.ready);
    expect(ready.snapshot.isEmpty, isTrue);

    open = false;
    sessionStates.add(const SecureSessionState(status: SecureStatus.locked));
    final locked = await settle(bloc, (s) => s.status == KeyBankStatus.locked);
    expect(locked.snapshot.directories, isEmpty);
    await bloc.close();
  });

  test('a locked section never loads', () async {
    whenListen(
      session,
      const Stream<SecureSessionState>.empty(),
      initialState: const SecureSessionState(status: SecureStatus.locked),
    );
    final bloc = build();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(bloc.state.status, KeyBankStatus.locked);
    bloc.add(const KeyBankAddOwnNumber('09121111111'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    verifyNever(() => crypto.canonicalPhone(any()));
    await bloc.close();
  });

  test(
    'importing a key file verifies it against the anchors and stores it',
    () async {
      when(
        () => crypto.openKeyFile(
          file: any(named: 'file'),
          password: any(named: 'password'),
          anchors: any(named: 'anchors'),
        ),
      ).thenAnswer((_) async => _opened());
      final bloc = build();
      await settle(bloc, (s) => s.status == KeyBankStatus.ready);
      bloc.add(KeyBankImportFile(_b(10, 1), 'ABCD'));
      final done = await settle(
        bloc,
        (s) => s.notice == KeyBankNotice.imported,
      );
      expect(done.busy, isFalse);
      expect(done.snapshot.directories.single.ownName, 'علی');
      final call = verify(
        () => crypto.openKeyFile(
          file: any(named: 'file'),
          password: 'ABCD',
          anchors: captureAny(named: 'anchors'),
        ),
      )..called(1);
      expect(call.captured.single, [_b(1985, 1)]);

      bloc.add(KeyBankImportFile(_b(10, 1), 'ABCD'));
      final again = await settle(
        bloc,
        (s) => s.notice == KeyBankNotice.alreadyImported,
      );
      expect(again.noticeSeq, done.noticeSeq + 1);
      await bloc.close();
    },
  );

  test('every key-file failure is its own notice', () async {
    const cases = {
      SmsCryptoFailure.wrongPassword: KeyBankNotice.wrongPassword,
      SmsCryptoFailure.notAKeyFile: KeyBankNotice.notAKeyFile,
      SmsCryptoFailure.untrusted: KeyBankNotice.untrusted,
      SmsCryptoFailure.badSignature: KeyBankNotice.badSignature,
      SmsCryptoFailure.badBundle: KeyBankNotice.badBundle,
      SmsCryptoFailure.failed: KeyBankNotice.failed,
    };
    final bloc = build();
    await settle(bloc, (s) => s.status == KeyBankStatus.ready);
    for (final entry in cases.entries) {
      when(
        () => crypto.openKeyFile(
          file: any(named: 'file'),
          password: any(named: 'password'),
          anchors: any(named: 'anchors'),
        ),
      ).thenThrow(SmsCryptoException(entry.key));
      bloc.add(KeyBankImportFile(_b(10, 1), 'x'));
      final s = await settle(bloc, (s) => s.notice == entry.value && !s.busy);
      expect(s.snapshot.directories, isEmpty);
    }
    await bloc.close();
  });

  group('the update file (update.hku)', () {
    /// The same organization, issued later: [members] as listed.
    OpenedKeyFile update({required int serial, required bool listsMe}) =>
        OpenedKeyFile(
          signed: _b(40, serial),
          directory: KeyDirectory(
            authorityId: _b(8, 0xAA),
            directoryId: _b(8, 1),
            serial: serial,
            name: 'سازمان',
            members: [
              DirectoryMember(
                name: 'علی',
                phones: const ['09121111111'],
                publicKey: listsMe ? _b(1217, 1) : _b(1217, 5),
                keyId: listsMe ? _b(8, 1) : _b(8, 5),
              ),
              DirectoryMember(
                name: 'مریم',
                phones: const ['09122222222'],
                publicKey: _b(1217, 2),
                keyId: _b(8, 2),
              ),
            ],
          ),
        );

    void opensAs(OpenedKeyFile o) => when(
      () => crypto.openUpdateFile(
        file: any(named: 'file'),
        directoryIds: any(named: 'directoryIds'),
        anchors: any(named: 'anchors'),
      ),
    ).thenAnswer((_) async => o);

    Future<KeyBankBloc> withMyKeyFile() async {
      when(
        () => crypto.openKeyFile(
          file: any(named: 'file'),
          password: any(named: 'password'),
          anchors: any(named: 'anchors'),
        ),
      ).thenAnswer((_) async => _opened());
      final bloc = build();
      await settle(bloc, (s) => s.status == KeyBankStatus.ready);
      bloc.add(KeyBankImportFile(_b(10, 1), 'ABCD'));
      await settle(bloc, (s) => s.notice == KeyBankNotice.imported);
      return bloc;
    }

    test('is told apart from a key file by its header', () {
      expect(
        SmsCryptoService.isUpdateFile(
          Uint8List.fromList([...'HMRKU'.codeUnits, 1, 2]),
        ),
        isTrue,
      );
      expect(
        SmsCryptoService.isUpdateFile(
          Uint8List.fromList([...'HMRKB'.codeUnits, 1, 2]),
        ),
        isFalse,
      );
      expect(
        SmsCryptoService.isUpdateFile(Uint8List.fromList('HMRKU'.codeUnits)),
        isFalse,
      );
    });

    test('brings the directory up to date and keeps our key', () async {
      final bloc = await withMyKeyFile();
      opensAs(update(serial: 200, listsMe: true));
      bloc.add(KeyBankImportUpdate(_b(10, 7)));
      final done = await settle(
        bloc,
        (s) => s.notice == KeyBankNotice.updated && !s.busy,
      );
      final d = done.snapshot.directories.single;
      expect(d.memberCount, 2);
      expect(d.serial, 200);
      expect(d.ownName, 'علی');
      final call = verify(
        () => crypto.openUpdateFile(
          file: any(named: 'file'),
          directoryIds: captureAny(named: 'directoryIds'),
          anchors: any(named: 'anchors'),
        ),
      )..called(1);
      expect(call.captured.single, [_b(8, 1)]); // the directory we hold
      await bloc.close();
    });

    test('says so when our own key was replaced', () async {
      final bloc = await withMyKeyFile();
      opensAs(update(serial: 200, listsMe: false));
      bloc.add(KeyBankImportUpdate(_b(10, 7)));
      final done = await settle(
        bloc,
        (s) => s.notice == KeyBankNotice.ownKeyRetired,
      );
      expect(done.snapshot.directories.single.hasOwnKey, isFalse);
      await bloc.close();
    });

    test('an older one is refused', () async {
      final bloc = await withMyKeyFile();
      opensAs(update(serial: 50, listsMe: true));
      bloc.add(KeyBankImportUpdate(_b(10, 7)));
      final done = await settle(bloc, (s) => s.notice == KeyBankNotice.older);
      expect(done.snapshot.directories.single.serial, 100);
      await bloc.close();
    });

    test('a phone of another organization cannot use it', () async {
      final bloc = build();
      await settle(bloc, (s) => s.status == KeyBankStatus.ready);
      bloc.add(KeyBankImportUpdate(_b(10, 7)));
      await settle(
        bloc,
        (s) => s.notice == KeyBankNotice.updateNotForThisPhone,
      );
      verifyNever(
        () => crypto.openUpdateFile(
          file: any(named: 'file'),
          directoryIds: any(named: 'directoryIds'),
          anchors: any(named: 'anchors'),
        ),
      );
      await bloc.close();

      final member = await withMyKeyFile();
      when(
        () => crypto.openUpdateFile(
          file: any(named: 'file'),
          directoryIds: any(named: 'directoryIds'),
          anchors: any(named: 'anchors'),
        ),
      ).thenThrow(const SmsCryptoException(SmsCryptoFailure.wrongPassword));
      member.add(KeyBankImportUpdate(_b(10, 7)));
      final s = await settle(
        member,
        (s) => s.notice == KeyBankNotice.updateNotForThisPhone && !s.busy,
      );
      expect(s.snapshot.directories.single.serial, 100);
      await member.close();
    });
  });

  test('a group is derived and stored; its code is kept for display', () async {
    when(
      () => crypto.deriveGroup(
        name: any(named: 'name'),
        passphrase: any(named: 'passphrase'),
      ),
    ).thenAnswer((_) async => (group: _b(33, 5), groupId: _b(8, 0x61)));
    final bloc = build();
    await settle(bloc, (s) => s.status == KeyBankStatus.ready);
    bloc.add(const KeyBankAddGroup('گروه', 'عبارت عبور طولانی'));
    final s = await settle(bloc, (s) => s.notice == KeyBankNotice.groupAdded);
    expect(s.lastGroupId, '6161616161616161');
    expect(s.snapshot.groups.single.name, 'گروه');
    bloc.add(const KeyBankAddGroup('گروه', 'عبارت عبور طولانی'));
    await settle(bloc, (s) => s.notice == KeyBankNotice.groupExists);
    await bloc.close();
  });

  test('own numbers are stored canonical; a non-number is refused', () async {
    when(
      () => crypto.canonicalPhone('+98 912 111 1111'),
    ).thenAnswer((_) async => '09121111111');
    when(() => crypto.canonicalPhone('abc')).thenAnswer((_) async => null);
    final bloc = build();
    await settle(bloc, (s) => s.status == KeyBankStatus.ready);
    bloc.add(const KeyBankAddOwnNumber('+98 912 111 1111'));
    final added = await settle(
      bloc,
      (s) => s.notice == KeyBankNotice.numberAdded,
    );
    expect(added.snapshot.ownNumbers, ['09121111111']);
    bloc.add(const KeyBankAddOwnNumber('abc'));
    await settle(bloc, (s) => s.notice == KeyBankNotice.notANumber);
    bloc.add(const KeyBankRemoveOwnNumber('09121111111'));
    await settle(bloc, (s) => s.snapshot.ownNumbers.isEmpty);
    await bloc.close();
  });
}
