import 'dart:convert';

import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart'
    show keyHex;
import 'package:communication_super_app/features/secure/repositories/secure_group_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';
import 'package:communication_super_app/features/hidden/services/sealed_inbox.dart';
import 'package:communication_super_app/features/secure_sms/repositories/secure_queue_repository.dart';
import 'package:communication_super_app/features/secure_sms/services/hidden_sms_source.dart';
import 'package:communication_super_app/features/secure_sms/services/secure_identities.dart';
import 'package:communication_super_app/features/secure_sms/services/secure_messenger.dart';
import 'package:communication_super_app/features/secure_sms/services/secure_sms_sender.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── A transparent stand-in for the Kotlin crypto ──────────────────────────────
//
// The real primitives are pinned by 76 JVM tests; this checks the ENGINE: the
// handshake order, reordering, crossed requests, duplicates, receipts. Packets
// are readable JSON behind the real prefix, and states record just enough to
// behave like the ratchet (counters, duplicate detection, session ids).

Uint8List _kid(String who) =>
    Uint8List.fromList(utf8.encode(who.padRight(8, '_').substring(0, 8)));

String _wire(Map<String, Object?> m) =>
    '#E:${base64Url.encode(utf8.encode(jsonEncode(m)))}';

Map<String, dynamic> _unwire(String wire) =>
    jsonDecode(utf8.decode(base64Url.decode(wire.substring(3))))
        as Map<String, dynamic>;

Uint8List _state(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

Map<String, dynamic> _unstate(Uint8List s) =>
    jsonDecode(utf8.decode(s)) as Map<String, dynamic>;

class FakeCrypto implements SmsCryptoService {
  FakeCrypto(this.seed);
  int seed;

  @override
  Future<String?> canonicalPhone(String phone) async =>
      phone.replaceAll(RegExp(r'\D'), '');

  @override
  Future<SmsPacketInfo?> inspect(String text) async {
    if (!text.startsWith('#E:')) return null;
    final m = _unwire(text);
    return SmsPacketInfo(
      type: SmsPacketType.values.byName(m['t'] as String),
      sid: m['sid'] as int,
      counter: m['n'] as int?,
      control: m['control'] == true,
      senderKid: m['from'] == null
          ? null
          : Uint8List.fromList(utf8.encode(m['from'] as String)),
      recipientKid: m['to'] == null
          ? null
          : Uint8List.fromList(utf8.encode(m['to'] as String)),
    );
  }

  String _who(Uint8List key) => utf8.decode(key.sublist(0, 8));

  @override
  Future<SmsSealed> initiate({
    required Uint8List secret,
    required Uint8List peer,
    Set<int> busySids = const {},
  }) async {
    var sid = seed++;
    while (busySids.contains(sid)) {
      sid = seed++;
    }
    return SmsSealed(
      state: _state({'sid': sid, 'own': _who(secret), 'peer': _who(peer)}),
      wire: _wire({
        't': 'init',
        'sid': sid,
        'from': _who(secret),
        'to': _who(peer),
      }),
      parts: 10,
      sid: sid,
    );
  }

  @override
  Future<SmsSealed> respond({
    required Uint8List secret,
    required Uint8List peer,
    required String text,
  }) async {
    final m = _unwire(text);
    if (m['from'] != _who(peer)) {
      throw const SmsCryptoException(SmsCryptoFailure.wrongPeer);
    }
    if (m['to'] != _who(secret)) {
      throw const SmsCryptoException(SmsCryptoFailure.notForUs);
    }
    final sid = m['sid'] as int;
    return SmsSealed(
      state: _state({'sid': sid, 'send': 0, 'got': <int>[]}),
      wire: _wire({
        't': 'response',
        'sid': sid,
        'from': _who(secret),
        'to': _who(peer),
      }),
      parts: 11,
      sid: sid,
    );
  }

  @override
  Future<Uint8List> complete({
    required Uint8List secret,
    required Uint8List peer,
    required Uint8List pending,
    required String text,
  }) async {
    final m = _unwire(text);
    final p = _unstate(pending);
    if (m['sid'] != p['sid']) {
      throw const SmsCryptoException(SmsCryptoFailure.wrongSession);
    }
    if (m['from'] != _who(peer)) {
      throw const SmsCryptoException(SmsCryptoFailure.wrongPeer);
    }
    return _state({'sid': p['sid'], 'send': 0, 'got': <int>[]});
  }

  SmsSealed _seal(
    Uint8List session,
    Map<String, Object?> body, {
    bool control = false,
  }) {
    final s = _unstate(session);
    final n = s['send'] as int;
    s['send'] = n + 1;
    return SmsSealed(
      state: _state(s),
      wire: _wire({
        't': 'message',
        'sid': s['sid'],
        'n': n,
        'control': control,
        ...body,
      }),
      parts: 1,
      sid: s['sid'] as int,
      counter: n,
    );
  }

  @override
  Future<SmsSealed> encryptText({
    required Uint8List session,
    required String text,
    bool deleteAfterSeen = false,
    Uint8List? groupId,
    int? ttlSeconds,
  }) async => _seal(session, {
    'kind': 'text',
    'text': text,
    'del': deleteAfterSeen,
    if (groupId != null) 'gid': keyHex(groupId),
    if (ttlSeconds != null) 'ttl': ttlSeconds,
  });

  @override
  Future<SmsSealed> encryptGroupInfo({
    required Uint8List session,
    required SmsGroupInfo info,
  }) async => _seal(session, {
    'kind': 'groupInfo',
    'gid': keyHex(info.groupId),
    'ver': info.version,
    'mode': info.mode.index,
    'name': info.name,
    'members': [
      for (final m in info.members) {'phone': m.phone, 'kid': keyHex(m.keyId)},
    ],
  }, control: true);

  @override
  Future<SmsSealed> encryptControl({
    required Uint8List session,
    required String control,
    required int refSid,
    required int refCounter,
  }) async => _seal(session, {
    'kind': control,
    'refSid': refSid,
    'refCounter': refCounter,
  }, control: true);

  @override
  Future<SmsDecrypted> decrypt({
    required Uint8List session,
    required String text,
  }) async {
    final s = _unstate(session);
    final m = _unwire(text);
    if (m['sid'] != s['sid']) {
      throw const SmsCryptoException(SmsCryptoFailure.wrongSession);
    }
    final got = (s['got'] as List).cast<int>();
    final n = m['n'] as int;
    if (got.contains(n)) {
      throw const SmsCryptoException(SmsCryptoFailure.duplicate);
    }
    s['got'] = [...got, n];
    return SmsDecrypted(
      session: _state(s),
      sid: m['sid'] as int,
      counter: n,
      kind: SmsPayloadKind.values.byName(m['kind'] as String),
      text: m['text'] as String?,
      deleteAfterSeen: m['del'] == true,
      refSid: m['refSid'] as int?,
      refCounter: m['refCounter'] as int?,
      groupId: m['gid'] == null ? null : _unhex(m['gid'] as String),
      ttlSeconds: m['ttl'] as int?,
      groupInfo: m['kind'] == 'groupInfo'
          ? SmsGroupInfo(
              groupId: _unhex(m['gid'] as String),
              version: m['ver'] as int,
              mode: SmsGroupMode.values[m['mode'] as int],
              name: m['name'] as String,
              members: [
                for (final e in (m['members'] as List).cast<Map>())
                  SmsGroupMember(
                    phone: e['phone'] as String,
                    keyId: _unhex(e['kid'] as String),
                  ),
              ],
            )
          : null,
    );
  }

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  @override
  Future<bool> ownInitWins(Uint8List ownKid, Uint8List peerKid) async =>
      utf8.decode(ownKid).compareTo(utf8.decode(peerKid)) <= 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeIdentities implements SecureIdentities {
  FakeIdentities(this.me, this.book);
  final String me;

  /// name → number, the whole "directory".
  final Map<String, String> book;

  OwnIdentity get _own => OwnIdentity(
    identity: SmsIdentity(
      secret: _kid(me),
      publicKey: _kid(me),
      keyId: _kid(me),
    ),
    source: 'directory:d',
  );

  SecurePeer peer(String name) => SecurePeer(
    name: name,
    phone: book[name]!,
    publicKey: _kid(name),
    keyId: _hex(_kid(name)),
    source: 'directory:d',
    own: _own,
  );

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  @override
  Future<List<OwnIdentity>> own() async => [_own];

  @override
  Future<OwnIdentity?> ownByKeyId(String keyId) async =>
      keyId == _own.keyId ? _own : null;

  @override
  Future<SecurePeer?> byKeyId(String keyId, String phone) async {
    for (final name in book.keys) {
      if (_hex(_kid(name)) == keyId) return peer(name);
    }
    return null;
  }

  @override
  void reset() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeQueue implements SecureQueueRepository {
  final List<QueuedPacket> rows = [];
  var _id = 1;

  void add(String address, String body, int at) => rows.add(
    QueuedPacket(id: _id++, address: address, body: body, timestamp: at),
  );

  @override
  Future<List<QueuedPacket>> all() async => List.of(rows);

  @override
  Future<void> delete(Iterable<int> ids) async {
    final gone = ids.toSet();
    rows.removeWhere((r) => gone.contains(r.id));
  }
}

/// SMS from hidden contacts, as Kotlin would have sealed them.
class FakeHidden implements HiddenSmsSource {
  final List<SealedEntry> entries = [];
  final Map<String, String> names = {};
  var _id = 1;

  void add(
    String address,
    String body,
    int at, {
    Map<String, Object?> extra = const {},
  }) => entries.add(
    SealedEntry(
      id: _id++,
      record: {'address': address, 'body': body, 'timestamp': at, ...extra},
    ),
  );

  @override
  Future<List<SealedEntry>> take() async => List.of(entries);

  @override
  Future<void> remove(Iterable<int> ids) async {
    final gone = ids.toSet();
    entries.removeWhere((e) => gone.contains(e.id));
  }

  @override
  Future<String?> nameFor(String phone) async => names[phone];
}

/// The radio: holds what each phone sends until the test delivers it.
class Air {
  final List<({String from, String to, String wire})> inFlight = [];
  final Map<String, FakeQueue> queues = {};
  var failNext = false;
  var clock = 1000;

  SecureSmsSender senderFor(String from) => _Sender(this, from);

  /// Delivers everything in flight (in order, or as [order] picks).
  void deliver({List<int>? order, bool duplicate = false}) {
    final batch = List.of(inFlight);
    inFlight.clear();
    final picks = order ?? List.generate(batch.length, (i) => i);
    for (final i in picks) {
      final p = batch[i];
      queues[p.to]!.add(p.from, p.wire, clock++);
      if (duplicate) queues[p.to]!.add(p.from, p.wire, clock++);
    }
  }
}

class _Sender implements SecureSmsSender {
  _Sender(this.air, this.from);
  final Air air;
  final String from;

  @override
  Future<void> send(
    String phone,
    String wire, {
    required String trackingId,
    int? subscriptionId,
  }) async {
    if (air.failNext) {
      air.failNext = false;
      throw Exception('no service');
    }
    air.inFlight.add((from: from, to: phone, wire: wire));
  }
}

class Phone {
  Phone(
    this.name,
    this.number,
    this.db,
    this.air,
    Map<String, String> book,
    int seed,
  ) : identities = FakeIdentities(name, book),
      queue = FakeQueue(),
      hidden = FakeHidden() {
    store = SecureMessageStore(database: () => db);
    air.queues[number] = queue;
    groups = SecureGroupStore(database: () => db);
    messenger = SecureMessenger(
      store: store,
      groups: groups,
      queue: queue,
      identities: identities,
      crypto: FakeCrypto(seed),
      sender: air.senderFor(number),
      hidden: hidden,
      clock: () => air.clock++,
    );
  }

  final String name;
  final String number;
  final Database db;
  final Air air;
  final FakeIdentities identities;
  final FakeQueue queue;
  final FakeHidden hidden;
  late final SecureMessageStore store;
  late final SecureGroupStore groups;
  late final SecureMessenger messenger;

  Future<List<SecureMessage>> thread(String phone) => store.messages(phone);
}

void main() {
  late Air air;
  late Phone ali;
  late Phone sara;
  late Phone reza;
  const book = {
    'ali': '09121111111',
    'sara': '09122222222',
    'reza': '09123333333',
    'mallory': '09129999999',
  };

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    air = Air();
    Future<Database> open() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await SecureStore.createSchemaForTest(db);
      return db;
    }

    ali = Phone('ali', book['ali']!, await open(), air, book, 100);
    sara = Phone('sara', book['sara']!, await open(), air, book, 200);
    reza = Phone('reza', book['reza']!, await open(), air, book, 300);
  });

  tearDown(() async {
    await ali.db.close();
    await sara.db.close();
    await reza.db.close();
  });

  /// Delivers and drains until nothing is in flight.
  Future<void> settle() async {
    for (var i = 0; i < 10 && air.inFlight.isNotEmpty; i++) {
      air.deliver();
      await ali.messenger.drain();
      await sara.messenger.drain();
      await reza.messenger.drain();
    }
  }

  test('the first message waits for the handshake, then arrives', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'سلام');
    expect(air.inFlight.single.wire, contains('#E:')); // the INIT, not the text
    expect(
      (await ali.thread(book['sara']!)).single.status,
      SecureMessageStatus.queued,
    );

    await settle();
    final got = await sara.thread(book['ali']!);
    expect(got.single.body, 'سلام');
    expect(got.single.outgoing, isFalse);
    expect(
      (await ali.thread(book['sara']!)).single.status,
      SecureMessageStatus.sent,
    );
    expect((await sara.store.conversation(book['ali']!))!.unread, 1);
    expect(ali.queue.rows, isEmpty);
    expect(sara.queue.rows, isEmpty);
  });

  test('a reply that overtakes the handshake answer waits for it', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'سلام');
    air.deliver(); // INIT → sara
    await sara.messenger.drain(); // RESPONSE in flight
    await sara.messenger.sendText(book['ali']!, 'علیک'); // sent at once
    expect(air.inFlight, hasLength(2));
    air.deliver(order: [1, 0]); // the reply arrives BEFORE the response
    await ali.messenger.drain();
    await settle();
    expect((await ali.thread(book['sara']!)).map((m) => m.body), [
      'سلام',
      'علیک',
    ]);
    expect((await sara.thread(book['ali']!)).map((m) => m.body), [
      'علیک',
      'سلام',
    ]);
  });

  test(
    'crossed requests end in one session and both messages arrive',
    () async {
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await sara.messenger.startConversation(sara.identities.peer('ali'));
      await ali.messenger.sendText(book['sara']!, 'از علی');
      await sara.messenger.sendText(book['ali']!, 'از سارا');
      expect(air.inFlight, hasLength(2)); // two INITs crossing
      await settle();
      expect((await ali.thread(book['sara']!)).map((m) => m.body).toSet(), {
        'از علی',
        'از سارا',
      });
      expect((await sara.thread(book['ali']!)).map((m) => m.body).toSet(), {
        'از علی',
        'از سارا',
      });
      final aliSessions = await ali.store.sessions(book['sara']!);
      final saraSessions = await sara.store.sessions(book['ali']!);
      expect(
        aliSessions.where((s) => !s.pending).map((s) => s.sid).toSet(),
        saraSessions.where((s) => !s.pending).map((s) => s.sid).toSet(),
      );
      expect(aliSessions.where((s) => s.pending), isEmpty);
      expect(saraSessions.where((s) => s.pending), isEmpty);
    },
  );

  test(
    'a dual-SIM peer answering from its other number is still them',
    () async {
      // Sara's phone sends from a SIM whose number the key bank does not
      // list: every packet of hers arrives from 09127777777.
      const otherSim = '09127777777';
      Future<void> deliverAll() async {
        for (var i = 0; i < 10 && air.inFlight.isNotEmpty; i++) {
          final batch = List.of(air.inFlight);
          air.inFlight.clear();
          for (final p in batch) {
            final from = p.from == book['sara'] ? otherSim : p.from;
            final to = p.to == otherSim ? book['sara']! : p.to;
            air.queues[to]!.add(from, p.wire, air.clock++);
          }
          await ali.messenger.drain();
          await sara.messenger.drain();
        }
      }

      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.sendText(book['sara']!, 'سلام');
      await deliverAll();
      // The answer came from the other SIM, and still opened the channel.
      expect(
        (await ali.thread(book['sara']!)).single.status,
        SecureMessageStatus.sent,
      );
      expect((await sara.thread(book['ali']!)).single.body, 'سلام');

      // Her reply, from the other SIM too, lands in the same conversation.
      await sara.messenger.sendText(book['ali']!, 'علیک');
      await deliverAll();
      expect((await ali.thread(book['sara']!)).map((m) => m.body), [
        'سلام',
        'علیک',
      ]);
      expect(await ali.store.conversation(otherSim), isNull);

      // A fresh request from the other SIM rejoins the known conversation.
      await sara.messenger.deleteConversation(book['ali']!);
      await sara.messenger.startConversation(sara.identities.peer('ali'));
      await sara.messenger.sendText(book['ali']!, 'دوباره');
      await deliverAll();
      expect((await ali.thread(book['sara']!)).last.body, 'دوباره');
      expect(await ali.store.conversation(otherSim), isNull);
    },
  );

  test('an SMS delivered twice is one message', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'یک');
    await settle();
    await ali.messenger.sendText(book['sara']!, 'دو');
    air.deliver(duplicate: true);
    await sara.messenger.drain();
    expect((await sara.thread(book['ali']!)).map((m) => m.body), ['یک', 'دو']);
  });

  test('«دیده شد» is one receipt for everything new', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    for (final t in ['۱', '۲', '۳']) {
      await ali.messenger.sendText(book['sara']!, t);
    }
    await settle();
    await sara.messenger.markSeen(book['ali']!);
    expect(air.inFlight, hasLength(1));
    await settle();
    final mine = await ali.thread(book['sara']!);
    expect(mine.map((m) => m.status), everyElement(SecureMessageStatus.seen));
    // Nothing new: no second receipt.
    await sara.messenger.markSeen(book['ali']!);
    expect(air.inFlight, isEmpty);
    expect((await sara.store.conversation(book['ali']!))!.unread, 0);
  });

  test('receipts can be turned off', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'x');
    await settle();
    await sara.messenger.setSendsSeenReceipts(false);
    await sara.messenger.markSeen(book['ali']!);
    expect(air.inFlight, isEmpty);
    expect((await sara.thread(book['ali']!)).single.seenAt, isNotNull);
  });

  test('«حذف برای هر دو» removes it on both phones', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'اشتباه');
    await ali.messenger.sendText(book['sara']!, 'درست');
    await settle();
    final wrong = (await ali.thread(book['sara']!)).first;
    await ali.messenger.deleteForBoth(wrong.id);
    await settle();
    expect((await ali.thread(book['sara']!)).map((m) => m.body), ['درست']);
    expect((await sara.thread(book['ali']!)).map((m) => m.body), ['درست']);
  });

  test('«حذف پس از دیدن» goes once shown and left, not before', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(
      book['sara']!,
      'محرمانه',
      deleteAfterSeen: true,
    );
    await ali.messenger.sendText(book['sara']!, 'عادی');
    await settle();
    await sara.messenger.leaveConversation(book['ali']!); // never shown yet
    expect((await sara.thread(book['ali']!)), hasLength(2));
    await sara.messenger.markSeen(book['ali']!);
    await sara.messenger.leaveConversation(book['ali']!);
    expect((await sara.thread(book['ali']!)).map((m) => m.body), ['عادی']);
    // The sender keeps its own copy.
    expect((await ali.thread(book['sara']!)), hasLength(2));
  });

  test('a failed send is retried under a new counter', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'اول');
    await settle();
    air.failNext = true;
    await ali.messenger.sendText(book['sara']!, 'دوم');
    final failed = (await ali.thread(book['sara']!)).last;
    expect(failed.status, SecureMessageStatus.failed);
    await ali.messenger.retry(failed.id);
    await settle();
    expect((await sara.thread(book['ali']!)).map((m) => m.body), [
      'اول',
      'دوم',
    ]);
    final resent = (await ali.thread(book['sara']!)).last;
    expect(resent.counter, isNot(failed.counter));
  });

  test('a request from a key the bank does not know is dropped', () async {
    final malloryDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await SecureStore.createSchemaForTest(malloryDb);
    addTearDown(malloryDb.close);
    final mallory = Phone('mallory', book['mallory']!, malloryDb, air, {
      'ali': book['ali']!,
      'mallory': book['mallory']!,
    }, 900);
    // Sara's book knows mallory's name but a different key id would be
    // needed to fool her; here mallory writes to a key sara does not hold.
    await mallory.messenger.startConversation(mallory.identities.peer('ali'));
    await mallory.messenger.sendText(book['ali']!, 'hi');
    final init = air.inFlight.single;
    air.inFlight
      ..clear()
      ..add((from: init.from, to: book['sara']!, wire: init.wire));
    air.deliver();
    await sara.messenger.drain();
    expect(await sara.store.conversations(), isEmpty);
    expect(air.inFlight, isEmpty); // nothing answered
  });

  test(
    'a message whose handshake never comes is dropped after a while',
    () async {
      sara.queue.add(
        book['ali']!,
        _wire({'t': 'message', 'sid': 7, 'n': 0, 'kind': 'text', 'text': 'x'}),
        air.clock,
      );
      await sara.messenger.drain();
      expect(await sara.store.inbox(), hasLength(1)); // kept, waiting
      air.clock += SecureMessenger.maxWait.inMilliseconds + 1;
      await sara.messenger.drain();
      expect(await sara.store.inbox(), isEmpty);
    },
  );

  test('delivery reports move a message forward, never back', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'x');
    await settle();
    final id = (await ali.thread(book['sara']!)).single.id;
    await ali.messenger.onStatus(id, 'delivered');
    expect(
      (await ali.store.message(id))!.status,
      SecureMessageStatus.delivered,
    );
    await ali.messenger.onStatus(id, 'sent'); // late
    expect(
      (await ali.store.message(id))!.status,
      SecureMessageStatus.delivered,
    );
    await ali.messenger.onStatus(id, 'failed'); // late failure of a part
    expect(
      (await ali.store.message(id))!.status,
      SecureMessageStatus.delivered,
    );
  });

  group('hidden contacts (phase G)', () {
    test(
      'a plain SMS from a hidden contact is stored once, named, keyless',
      () async {
        ali.hidden.names['09125555555'] = 'رضا';
        ali.hidden.add('09125555555', 'سلام، کجایی؟', 5000);
        await ali.messenger.drain();
        // Kotlin parked it again (the delete failed): still one message.
        ali.hidden.add('09125555555', 'سلام، کجایی؟', 5000);
        await ali.messenger.drain();

        final c = (await ali.store.conversation('09125555555'))!;
        expect(c.name, 'رضا');
        expect(c.encrypted, isFalse);
        expect(c.unread, 1);
        final m = (await ali.thread('09125555555')).single;
        expect(m.plain, isTrue);
        expect(m.outgoing, isFalse);
        expect(m.body, 'سلام، کجایی؟');
        expect(ali.hidden.entries, isEmpty);
      },
    );

    test(
      'an encrypted SMS from a hidden contact goes through the engine',
      () async {
        ali.hidden.names[book['sara']!] = 'سارا (مخفی)';
        await sara.messenger.startConversation(sara.identities.peer('ali'));
        await sara.messenger.sendText(book['ali']!, 'رمزی');
        // Ali's phone knows Sara as hidden: Kotlin sealed her SMS instead of
        // queueing them.
        for (var i = 0; i < 5 && air.inFlight.isNotEmpty; i++) {
          final batch = List.of(air.inFlight);
          air.inFlight.clear();
          for (final p in batch) {
            if (p.to == book['ali']) {
              ali.hidden.add(p.from, p.wire, air.clock++);
            } else {
              sara.queue.add(p.from, p.wire, air.clock++);
            }
          }
          await ali.messenger.drain();
          await sara.messenger.drain();
        }
        final got = (await ali.thread(book['sara']!)).single;
        expect(got.body, 'رمزی');
        expect(got.plain, isFalse);
        expect(
          (await ali.store.conversation(book['sara']!))!.name,
          'سارا (مخفی)',
        );
      },
    );

    test(
      'a keyless conversation sends plain SMS at once, never a handshake',
      () async {
        await ali.messenger.startPlainConversation('09125555555', 'رضا');
        await ali.messenger.sendPlain('09125555555', 'بدون رمز');
        final sent = air.inFlight.single;
        expect(sent.wire, 'بدون رمز');
        final m = (await ali.thread('09125555555')).single;
        expect(m.plain, isTrue);
        expect(m.status, SecureMessageStatus.sent);
        await ali.messenger.flush('09125555555'); // nothing to encrypt
        expect(air.inFlight, hasLength(1));
        expect(await ali.store.sessions('09125555555'), isEmpty);
      },
    );

    test('a failed plain SMS is retried as plain', () async {
      await ali.messenger.startPlainConversation('09125555555', 'رضا');
      air.failNext = true;
      await ali.messenger.sendPlain('09125555555', 'دوباره');
      final failed = (await ali.thread('09125555555')).single;
      expect(failed.status, SecureMessageStatus.failed);
      await ali.messenger.retry(failed.id);
      expect(air.inFlight.single.wire, 'دوباره');
      expect(
        (await ali.store.message(failed.id))!.status,
        SecureMessageStatus.sent,
      );
    });

    test('moved history is stored once, already read', () async {
      final history = [
        (outgoing: false, body: 'قدیمی ۱', timestamp: 10),
        (outgoing: true, body: 'قدیمی ۲', timestamp: 20),
      ];
      await ali.messenger.importPlainHistory('09125555555', 'رضا', history);
      await ali.messenger.importPlainHistory('09125555555', 'رضا', history);
      final thread = await ali.thread('09125555555');
      expect(thread.map((m) => m.body), ['قدیمی ۱', 'قدیمی ۲']);
      expect(thread.every((m) => m.plain), isTrue);
      expect(thread.first.seenAt, isNotNull);
      final c = (await ali.store.conversation('09125555555'))!;
      expect(c.unread, 0);
      expect(c.lastAt, 20);
    });

    test(
      'a scheduled SMS sent to a hidden number lands as ours, read',
      () async {
        ali.hidden.names['09125555555'] = 'رضا';
        ali.hidden.add(
          '09125555555',
          'زمان‌بندی‌شده',
          7000,
          extra: {'outgoing': true},
        );
        await ali.messenger.drain();
        final m = (await ali.thread('09125555555')).single;
        expect(m.outgoing, isTrue);
        expect(m.plain, isTrue);
        expect(m.status, SecureMessageStatus.sent);
        expect((await ali.store.conversation('09125555555'))!.unread, 0);
      },
    );

    test(
      'an operator notice naming a hidden number joins that conversation',
      () async {
        ali.hidden.names['09125555555'] = 'رضا';
        ali.hidden.add(
          'MCI',
          'تماس از 09125555555',
          8000,
          extra: {'about': '09125555555'},
        );
        await ali.messenger.drain();
        expect(await ali.store.conversation('MCI'), isNull);
        final m = (await ali.thread('09125555555')).single;
        expect(m.body, 'پیامک MCI: تماس از 09125555555');
        expect(m.outgoing, isFalse);
        expect((await ali.store.conversation('09125555555'))!.name, 'رضا');
      },
    );

    test(
      'a key-bank conversation keeps its key when the contact is hidden',
      () async {
        await ali.messenger.startConversation(ali.identities.peer('sara'));
        await ali.messenger.startPlainConversation(book['sara']!, 'سارا');
        final c = (await ali.store.conversation(book['sara']!))!;
        expect(c.encrypted, isTrue);
        expect(c.name, 'سارا');
      },
    );
  });

  group('timed messages (matrix row 16)', () {
    test('ours goes ttl after sending, theirs ttl after it is shown', () async {
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.sendText(book['sara']!, 'زمان‌دار', ttl: 30);
      await ali.messenger.sendText(book['sara']!, 'ماندگار');
      await settle();
      final got = (await sara.thread(book['ali']!)).first;
      expect(got.ttl, 30);
      expect(got.expiresAt, isNull); // not shown yet: the clock has not started

      air.clock += 31000;
      expect(await ali.messenger.purgeExpired(), 1);
      expect((await ali.thread(book['sara']!)).map((m) => m.body), ['ماندگار']);
      // Never shown on Sara's phone: still there however long it waits.
      expect(await sara.messenger.purgeExpired(), 0);
      expect(await sara.thread(book['ali']!), hasLength(2));

      await sara.messenger.markSeen(book['ali']!);
      final shown = (await sara.thread(book['ali']!)).first;
      expect(shown.expiresAt, shown.seenAt! + 30000);
      expect(await sara.messenger.nextExpiry(), shown.expiresAt);
      air.clock += 31000;
      expect(await sara.messenger.purgeExpired(), 1);
      expect((await sara.thread(book['ali']!)).map((m) => m.body), ['ماندگار']);
      expect(await sara.messenger.nextExpiry(), isNull);
    });

    test(
      'a timed group message carries its lifetime to every member',
      () async {
        final id = await ali.messenger.createGroup(
          name: 'تیم',
          mode: SecureGroupMode.chat,
          members: [ali.identities.peer('sara'), ali.identities.peer('reza')],
        );
        await settle();
        await ali.messenger.sendGroupText(id, 'تا یک ساعت', ttl: 3600);
        await settle();
        for (final p in [sara, reza]) {
          final m = (await p.groups.messages(id)).single;
          expect(m.ttl, 3600);
          expect(m.expiresAt, isNull);
          await p.messenger.markGroupSeen(id);
        }
        air.clock += 3600 * 1000 + 1;
        for (final p in [ali, sara, reza]) {
          expect(await p.messenger.purgeExpired(), 1);
          expect(await p.groups.messages(id), isEmpty);
        }
      },
    );
  });

  group('encrypted groups (matrix row 14)', () {
    Future<String> makeGroup({
      SecureGroupMode mode = SecureGroupMode.chat,
      String name = 'تیم میدانی',
    }) async {
      final id = await ali.messenger.createGroup(
        name: name,
        mode: mode,
        members: [ali.identities.peer('sara'), ali.identities.peer('reza')],
      );
      await settle();
      return id;
    }

    test('a group reaches every member, definition first', () async {
      final id = await makeGroup();
      for (final p in [sara, reza]) {
        final g = (await p.groups.group(id))!;
        expect(g.name, 'تیم میدانی');
        expect(g.creator, book['ali']);
        expect(g.pendingInfo, isFalse);
        expect(g.left, isFalse);
      }
      // Each sees the other member; the creator is implied.
      expect((await sara.groups.group(id))!.members.map((m) => m.phone), [
        book['reza'],
      ]);
      expect((await reza.groups.group(id))!.members.map((m) => m.phone), [
        book['sara'],
      ]);

      await ali.messenger.sendGroupText(id, 'سلام به همه');
      await settle();
      for (final p in [sara, reza]) {
        final got = (await p.groups.messages(id)).single;
        expect(got.body, 'سلام به همه');
        expect(got.sender, book['ali']);
        expect((await p.groups.group(id))!.unread, 1);
      }
      // The pairwise conversations a group needs stay out of the list.
      expect(await ali.store.conversations(), isEmpty);
      expect(await sara.store.conversations(), isEmpty);
    });

    test('in a chat group a reply goes to everyone', () async {
      final id = await makeGroup();
      await sara.messenger.sendGroupText(id, 'من هم هستم');
      await settle(); // Sara and Reza had no session: it is made on the way
      expect((await ali.groups.messages(id)).single.sender, book['sara']);
      expect((await reza.groups.messages(id)).single.body, 'من هم هستم');
      final mine = (await sara.groups.messages(id)).single;
      expect(mine.deliveries.map((d) => d.phone).toSet(), {
        book['ali'],
        book['reza'],
      });
    });

    test('in an announcement list a reply goes to the creator only', () async {
      final id = await makeGroup(mode: SecureGroupMode.announce);
      await sara.messenger.sendGroupText(id, 'دریافت شد');
      await settle();
      expect((await ali.groups.messages(id)).single.body, 'دریافت شد');
      expect(await reza.groups.messages(id), isEmpty);
    });

    test('one «دیده شد» per member makes «seen by 2 of 2»', () async {
      final id = await makeGroup();
      await ali.messenger.sendGroupText(id, 'خوانده شود');
      await settle();
      await sara.messenger.markGroupSeen(id);
      await settle();
      var m = (await ali.groups.messages(id)).single;
      expect(m.count(SecureMessageStatus.seen), 1);
      await reza.messenger.markGroupSeen(id);
      await settle();
      m = (await ali.groups.messages(id)).single;
      expect(m.count(SecureMessageStatus.seen), 2);
      expect((await sara.groups.group(id))!.unread, 0);
    });

    test('a removed member is told, and can no longer send', () async {
      final id = await makeGroup();
      await ali.messenger.editGroup(
        id,
        name: 'تیم کوچک',
        members: [ali.identities.peer('sara')],
      );
      await settle();
      final left = (await reza.groups.group(id))!;
      expect(left.left, isTrue);
      final kept = (await sara.groups.group(id))!;
      expect(kept.name, 'تیم کوچک');
      expect(kept.members, isEmpty);
      expect(await ali.groups.allMembers(id), hasLength(1)); // told, dropped

      await reza.messenger.sendGroupText(id, 'هنوز هستم؟');
      expect(air.inFlight, isEmpty);
    });

    test('only the creator defines a group', () async {
      final id = await makeGroup();
      // Sara pretends the group is hers and "redefines" it.
      await sara.groups.deleteGroup(id);
      await sara.groups.createGroup(
        id: id,
        name: 'ربوده',
        mode: SecureGroupMode.chat,
        members: [
          (phone: book['reza']!, keyId: sara.identities.peer('reza').keyId),
          (phone: book['ali']!, keyId: sara.identities.peer('ali').keyId),
        ],
        now: 1,
      );
      await sara.messenger.editGroup(
        id,
        name: 'ربوده',
        members: [sara.identities.peer('reza'), sara.identities.peer('ali')],
      );
      await settle();
      expect((await reza.groups.group(id))!.name, 'تیم میدانی');
      expect((await ali.groups.group(id))!.name, 'تیم میدانی');
      expect((await ali.groups.group(id))!.isMine, isTrue);
    });

    test('«حذف برای هر دو» removes every member\'s copy', () async {
      final id = await makeGroup();
      await ali.messenger.sendGroupText(id, 'اشتباهی');
      await settle();
      final m = (await ali.groups.messages(id)).single;
      await ali.messenger.deleteGroupMessageForAll(m.id);
      await settle();
      expect(await sara.groups.messages(id), isEmpty);
      expect(await reza.groups.messages(id), isEmpty);
      expect(await ali.groups.messages(id), isEmpty);
    });

    test(
      'a message that overtakes its group\'s definition waits, then fits',
      () async {
        await makeGroup(); // sessions exist now
        final id = await ali.messenger.createGroup(
          name: 'دوم',
          mode: SecureGroupMode.chat,
          members: [ali.identities.peer('sara')],
        );
        await ali.messenger.sendGroupText(id, 'زودتر رسید');
        expect(air.inFlight, hasLength(2)); // definition, then the message
        air.deliver(order: [1, 0]);
        await sara.messenger.drain();
        final g = (await sara.groups.group(id))!;
        expect(g.pendingInfo, isFalse);
        expect(g.name, 'دوم');
        expect((await sara.groups.messages(id)).single.body, 'زودتر رسید');
      },
    );

    test('a failed copy is sent again, to that member only', () async {
      final id = await makeGroup();
      air.failNext = true;
      await ali.messenger.sendGroupText(id, 'دوباره');
      await settle();
      var m = (await ali.groups.messages(id)).single;
      expect(m.count(SecureMessageStatus.failed), 1);
      final got =
          (await sara.groups.messages(id)).length +
          (await reza.groups.messages(id)).length;
      expect(got, 1);

      await ali.messenger.retryGroupMessage(m.id);
      await settle();
      m = (await ali.groups.messages(id)).single;
      expect(m.count(SecureMessageStatus.failed), 0);
      expect((await sara.groups.messages(id)), hasLength(1));
      expect((await reza.groups.messages(id)), hasLength(1));
    });

    test('delivery reports reach a member\'s copy', () async {
      final id = await makeGroup();
      await ali.messenger.sendGroupText(id, 'گزارش');
      await settle();
      final m = (await ali.groups.messages(id)).single;
      await ali.messenger.onStatus(
        SecureMessenger.groupTrackingId(m.id, book['sara']!),
        'delivered',
      );
      final after = (await ali.groups.messages(id)).single;
      expect(after.count(SecureMessageStatus.delivered), 1);
      expect(after.count(SecureMessageStatus.sent), 1);
    });
  });
}
