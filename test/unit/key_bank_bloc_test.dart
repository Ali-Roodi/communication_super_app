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
  authorityId: _b(8, 0xAA),
  secret: _b(97, 9),
  cert: MemberCertInfo(
    cert: _b(103, 3),
    keyId: _b(8, 1),
    phone: '09121111111',
    generation: 0,
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
    expect(locked.snapshot.keys, isEmpty);
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
    bloc.add(KeyBankImportFile(_b(10, 1), 'ABCD'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    verifyNever(
      () => crypto.openKeyFile(
        file: any(named: 'file'),
        password: any(named: 'password'),
        anchors: any(named: 'anchors'),
      ),
    );
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
      expect(done.snapshot.keys.single.phone, '09121111111');
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
      expect(s.snapshot.keys, isEmpty);
    }
    await bloc.close();
  });

  test('removing the key empties the bank', () async {
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
    bloc.add(const KeyBankRemoveKey('0101010101010101'));
    final done = await settle(bloc, (s) => s.snapshot.isEmpty);
    expect(done.status, KeyBankStatus.ready);
    await bloc.close();
  });
}
