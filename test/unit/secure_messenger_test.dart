import 'dart:convert';

import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';
import 'package:communication_super_app/features/secure_sms/repositories/secure_queue_repository.dart';
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
  }) async =>
      _seal(session, {'kind': 'text', 'text': text, 'del': deleteAfterSeen});

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
    );
  }

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
      queue = FakeQueue() {
    store = SecureMessageStore(database: () => db);
    air.queues[number] = queue;
    messenger = SecureMessenger(
      store: store,
      queue: queue,
      identities: identities,
      crypto: FakeCrypto(seed),
      sender: air.senderFor(number),
      clock: () => air.clock++,
    );
  }

  final String name;
  final String number;
  final Database db;
  final Air air;
  final FakeIdentities identities;
  final FakeQueue queue;
  late final SecureMessageStore store;
  late final SecureMessenger messenger;

  Future<List<SecureMessage>> thread(String phone) => store.messages(phone);
}

void main() {
  late Air air;
  late Phone ali;
  late Phone sara;
  const book = {
    'ali': '09121111111',
    'sara': '09122222222',
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
  });

  tearDown(() async {
    await ali.db.close();
    await sara.db.close();
  });

  /// Delivers and drains until nothing is in flight.
  Future<void> settle() async {
    for (var i = 0; i < 10 && air.inFlight.isNotEmpty; i++) {
      air.deliver();
      await ali.messenger.drain();
      await sara.messenger.drain();
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
}
