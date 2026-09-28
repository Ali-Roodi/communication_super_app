import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/features/hidden/bloc/hidden_bloc.dart';
import 'package:communication_super_app/features/hidden/repositories/hidden_contacts_repository.dart';
import 'package:communication_super_app/features/hidden/services/hidden_history_mover.dart';
import 'package:communication_super_app/features/hidden/services/sealed_inbox.dart';
import 'package:communication_super_app/features/hidden/services/sealing_key.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure/services/hidden_bridge.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MockSession extends MockBloc<SecureSessionEvent, SecureSessionState>
    implements SecureSessionBloc {}

class _Bridge implements HiddenBridge {
  List<String> numbers = [];
  Map<String, String> names = {};
  var namesCleared = 0;
  var sweeps = 0;

  @override
  Future<bool> setNumbers(List<String> numbers) async {
    final changed = !listEquals(numbers, this.numbers);
    this.numbers = List.of(numbers);
    return changed;
  }

  @override
  Future<void> setNames(Map<String, String> names) async =>
      this.names = Map.of(names);

  @override
  Future<void> clearNames() async {
    names = {};
    namesCleared++;
  }

  @override
  Future<int> sweep({bool full = false}) async {
    sweeps++;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _Key implements SealingKey {
  var ensured = 0;
  final secretBytes = Uint8List.fromList([1, 2, 3]);

  @override
  Future<Uint8List> ensure() async {
    ensured++;
    return secretBytes;
  }

  @override
  Future<Uint8List?> secret() async => secretBytes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sealed implements SealedInbox {
  final List<SealedEntry> calls = [];
  var _id = 1;

  void addCall(String number, int type, int date) => calls.add(
    SealedEntry(
      id: _id++,
      record: {
        'k': 'call',
        'number': number,
        'type': type,
        'date': date,
        'duration': 12,
        'account': null,
      },
    ),
  );

  @override
  Future<List<SealedEntry>> open(String kind, Uint8List secret) async =>
      kind == SealedInbox.kindCall ? List.of(calls) : const [];

  @override
  Future<void> remove(Iterable<int> ids) async {
    final gone = ids.toSet();
    calls.removeWhere((e) => gone.contains(e.id));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Mover implements HiddenHistoryMover {
  final Map<String, List<MovedSms>> history = {};
  final List<String> smsPurged = [];
  final List<String> callsPurged = [];

  @override
  Future<List<MovedSms>> smsHistory(String phone) async =>
      history[phone] ?? const [];

  @override
  Future<void> purgeSms(String phone) async => smsPurged.add(phone);

  @override
  Future<void> purgeCalls(String phone) async => callsPurged.add(phone);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Crypto implements SmsCryptoService {
  const _Crypto();

  /// Digits only; too short is "not a phone number".
  @override
  Future<String?> canonicalPhone(String phone) async {
    final d = phone.replaceAll(RegExp(r'\D'), '');
    return d.length < 5 ? null : d;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Database db;
  late _MockSession session;
  late StreamController<SecureSessionState> sessionStates;
  late StreamController<void> callLog;
  late _Bridge bridge;
  late _Key key;
  late _Sealed sealed;
  late _Mover mover;
  late List<(String, String, List<MovedSms>)> imported;
  late bool importSucceeds;
  late List<List<String>> moved;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SecureStore.createSchemaForTest(db);
    session = _MockSession();
    sessionStates = StreamController<SecureSessionState>.broadcast();
    whenListen(
      session,
      sessionStates.stream,
      initialState: const SecureSessionState(status: SecureStatus.unlocked),
    );
    callLog = StreamController<void>.broadcast();
    bridge = _Bridge();
    key = _Key();
    sealed = _Sealed();
    mover = _Mover();
    imported = [];
    importSucceeds = true;
    moved = [];
  });

  tearDown(() async {
    await sessionStates.close();
    await callLog.close();
    await db.close();
  });

  HiddenBloc build() => HiddenBloc(
    session: session,
    repository: HiddenContactsRepository(database: () => db),
    bridge: bridge,
    sealingKey: key,
    sealed: sealed,
    mover: mover,
    crypto: const _Crypto(),
    importHistory: (phone, name, history) async {
      imported.add((phone, name, history));
      return importSucceeds;
    },
    onHistoryMoved: moved.add,
    callLogChanges: callLog.stream,
    clock: () => 1000,
  );

  Future<HiddenState> ready(HiddenBloc bloc) =>
      bloc.stream.firstWhere((s) => s.status == HiddenStatus.ready);

  test(
    'opening makes the key, tells Kotlin, and drains sealed calls',
    () async {
      await HiddenContactsRepository(database: () => db).save(
        const HiddenContact(
          id: 'a',
          name: 'رضا',
          numbers: [HiddenNumber(phone: '09125555555')],
        ),
        1,
      );
      sealed.addCall('+989125555555', 3, 500);
      final bloc = build();
      final s = await ready(bloc);
      expect(key.ensured, 1);
      expect(bridge.numbers, ['09125555555']);
      expect(bridge.names, {'09125555555': 'رضا'});
      expect(bridge.sweeps, 1);
      expect(s.calls.single.phone, '989125555555'); // canonical, per the crypto
      expect(s.calls.single.callType, 3);
      expect(sealed.calls, isEmpty);
      await bloc.close();
    },
  );

  test(
    'saving refuses a bad number and a number another contact has',
    () async {
      final bloc = build();
      await ready(bloc);
      bloc.add(const HiddenSaveContact(id: 'a', name: 'رضا', numbers: ['12']));
      var s = await bloc.stream.firstWhere((s) => s.errorSeq == 1);
      expect(s.error, HiddenSaveError.badNumber);

      bloc.add(
        const HiddenSaveContact(id: 'a', name: 'رضا', numbers: ['09125555555']),
      );
      await bloc.stream.firstWhere((s) => s.savedSeq == 1);
      bloc.add(
        const HiddenSaveContact(
          id: 'b',
          name: 'مینا',
          numbers: ['0912 555 5555'],
        ),
      );
      s = await bloc.stream.firstWhere((s) => s.errorSeq == 2);
      expect(s.error, HiddenSaveError.numberTaken);
      expect(s.errorDetail, 'رضا');

      bloc.add(const HiddenSaveContact(id: 'c', name: ' ', numbers: ['0912']));
      s = await bloc.stream.firstWhere((s) => s.errorSeq == 3);
      expect(s.error, HiddenSaveError.noName);
      await bloc.close();
    },
  );

  test('a newly hidden number takes its history along — deleted only once '
      'the section has it', () async {
    mover.history['09125555555'] = [
      (outgoing: false, body: 'قدیمی', timestamp: 10),
    ];
    final bloc = build();
    await ready(bloc);
    bloc.add(
      const HiddenSaveContact(id: 'a', name: 'رضا', numbers: ['09125555555']),
    );
    final s = await bloc.stream.firstWhere(
      (s) => s.savedSeq == 1 && s.contacts.isNotEmpty,
    );
    expect(s.contacts.single.name, 'رضا');
    expect(bridge.numbers, ['09125555555']);
    expect(bridge.names, {'09125555555': 'رضا'});
    expect(imported.single.$1, '09125555555');
    expect(imported.single.$3.single.body, 'قدیمی');
    expect(mover.smsPurged, ['09125555555']);
    expect(mover.callsPurged, ['09125555555']);
    expect(moved, [
      ['09125555555'],
    ]);

    // Saving again (a rename) moves nothing a second time.
    bloc.add(
      const HiddenSaveContact(id: 'a', name: 'رضا ک', numbers: ['09125555555']),
    );
    await bloc.stream.firstWhere((s) => s.savedSeq == 2);
    expect(imported, hasLength(1));
    await bloc.close();
  });

  test('history the section did not take is not deleted', () async {
    importSucceeds = false;
    mover.history['09125555555'] = [(outgoing: true, body: 'x', timestamp: 10)];
    final bloc = build();
    await ready(bloc);
    bloc.add(
      const HiddenSaveContact(id: 'a', name: 'رضا', numbers: ['09125555555']),
    );
    await bloc.stream.firstWhere((s) => s.savedSeq == 1);
    expect(mover.smsPurged, isEmpty);
    expect(mover.callsPurged, ['09125555555']);
    await bloc.close();
  });

  test('a call-log change drains new sealed calls', () async {
    final bloc = build();
    await ready(bloc);
    sealed.addCall('09125555555', 2, 900);
    callLog.add(null);
    final s = await bloc.stream.firstWhere((s) => s.calls.isNotEmpty);
    expect(s.calls.single.callType, 2);
    await bloc.close();
  });

  test('deleting a contact stops hiding its numbers', () async {
    final bloc = build();
    await ready(bloc);
    bloc.add(
      const HiddenSaveContact(id: 'a', name: 'رضا', numbers: ['09125555555']),
    );
    await bloc.stream.firstWhere((s) => s.savedSeq == 1);
    bloc.add(const HiddenDeleteContact('a'));
    await bloc.stream.firstWhere((s) => s.contacts.isEmpty);
    expect(bridge.numbers, isEmpty);
    expect(bridge.names, isEmpty);
    await bloc.close();
  });

  test('locking drops the names from Kotlin and empties the state', () async {
    final bloc = build();
    await ready(bloc);
    sessionStates.add(const SecureSessionState(status: SecureStatus.locked));
    final s = await bloc.stream.firstWhere(
      (s) => s.status == HiddenStatus.locked,
    );
    expect(s.contacts, isEmpty);
    expect(bridge.namesCleared, 1);
    await bloc.close();
  });
}
