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
// The real primitives are pinned by the JVM tests; this checks the ENGINE: the
// handshake order, reordering, crossed requests, duplicates, receipts, the
// post-quantum upgrade. Packets
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

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// A fake member certificate (see [FakeCrypto]).
Uint8List fakeCert(String who, String phone, {int gen = 0, bool ok = true}) =>
    _bytes(jsonEncode({'who': who, 'phone': phone, 'gen': gen, 'ok': ok}));

MemberCertInfo fakeCertInfo(Uint8List cert) {
  final m = jsonDecode(utf8.decode(cert)) as Map;
  return MemberCertInfo(
    cert: cert,
    keyId: _kid('${m['who']}#${m['gen']}'),
    phone: m['phone'] as String,
    generation: m['gen'] as int,
  );
}

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
      senderKid: m['cert'] == null
          ? null
          : fakeCertInfo(_bytes(m['cert'] as String)).keyId,
      certPhone: m['cert'] == null
          ? null
          : fakeCertInfo(_bytes(m['cert'] as String)).phone,
      certGeneration: m['cert'] == null
          ? null
          : fakeCertInfo(_bytes(m['cert'] as String)).generation,
    );
  }

  String _who(Uint8List key) => utf8.decode(key.sublist(0, 8));

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
      pqKey: m['key'] == null ? null : _bytes(m['key'] as String),
      pqSid: m['pqSid'] as int?,
      pqCiphertext: m['ct'] == null ? null : _bytes(m['ct'] as String),
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

  // ── Certificates and the upgrade (fakes as transparent as the rest) ──────
  //
  // A certificate is JSON: who, phone, generation, and whether "the
  // authority signed it" (`ok`). Its key id is `<who>#<gen>`.

  /// Wire texts of every certificate request this crypto made, for a test
  /// to replay.
  final List<String> certInits = [];

  @override
  Future<MemberCertInfo> certInfo(Uint8List cert) async => fakeCertInfo(cert);

  @override
  Future<SmsSealed> certInitiate({
    required Uint8List cert,
    Set<int> busySids = const {},
  }) async {
    var sid = seed++;
    while (busySids.contains(sid)) {
      sid = seed++;
    }
    final wire = _wire({'t': 'init', 'sid': sid, 'cert': utf8.decode(cert)});
    certInits.add(wire);
    return SmsSealed(
      state: _state({'sid': sid, 'own': fakeCertInfo(cert).phone}),
      wire: wire,
      parts: 2,
      sid: sid,
    );
  }

  void _checkTrusted(MemberCertInfo peer, Uint8List raw) {
    if ((jsonDecode(utf8.decode(raw)) as Map)['ok'] != true) {
      throw const SmsCryptoException(SmsCryptoFailure.untrusted);
    }
  }

  @override
  Future<SmsCertHandshake> certRespond({
    required Uint8List secret,
    required Uint8List cert,
    required String text,
    required List<Uint8List> anchors,
  }) async {
    final m = _unwire(text);
    final raw = Uint8List.fromList(utf8.encode(m['cert'] as String));
    final peer = fakeCertInfo(raw);
    _checkTrusted(peer, raw);
    final sid = m['sid'] as int;
    return SmsCertHandshake(
      session: _state({'sid': sid, 'send': 0, 'got': <int>[], 'root': true}),
      sid: sid,
      peer: peer,
      wire: _wire({'t': 'response', 'sid': sid, 'cert': utf8.decode(cert)}),
      parts: 2,
    );
  }

  @override
  Future<SmsCertHandshake> certComplete({
    required Uint8List secret,
    required Uint8List cert,
    required Uint8List pending,
    required String text,
    required List<Uint8List> anchors,
  }) async {
    final m = _unwire(text);
    final p = _unstate(pending);
    if (m['sid'] != p['sid']) {
      throw const SmsCryptoException(SmsCryptoFailure.wrongSession);
    }
    final raw = Uint8List.fromList(utf8.encode(m['cert'] as String));
    final peer = fakeCertInfo(raw);
    _checkTrusted(peer, raw);
    return SmsCertHandshake(
      session: _state({
        'sid': p['sid'],
        'send': 0,
        'got': <int>[],
        'root': true,
      }),
      sid: p['sid'] as int,
      peer: peer,
    );
  }

  @override
  Future<SmsSealed> upgradeOffer({
    required Uint8List session,
    required Uint8List secret,
  }) async {
    if (_unstate(session)['root'] != true) {
      throw const SmsCryptoException(SmsCryptoFailure.wrongSession);
    }
    return _seal(session, {
      'kind': 'pqOffer',
      'key': _who(secret),
    }, control: true);
  }

  @override
  Future<SmsUpgradeAccepted> upgradeAccept({
    required Uint8List session,
    required Uint8List key,
    Set<int> busySids = const {},
  }) async {
    var sid = seed++;
    while (busySids.contains(sid)) {
      sid = seed++;
    }
    return SmsUpgradeAccepted(
      answer: _seal(session, {
        'kind': 'pqAccept',
        'pqSid': sid,
        'ct': 'ct-${utf8.decode(key)}',
      }, control: true),
      upgraded: _state({'sid': sid, 'send': 0, 'got': <int>[], 'pq': true}),
      upgradedSid: sid,
    );
  }

  @override
  Future<Uint8List> upgradeComplete({
    required Uint8List session,
    required Uint8List secret,
    required int sid,
    required Uint8List ciphertext,
  }) async {
    if (utf8.decode(ciphertext) != 'ct-${_who(secret)}') {
      throw const SmsCryptoException(SmsCryptoFailure.badPayload);
    }
    return _state({'sid': sid, 'send': 0, 'got': <int>[], 'pq': true});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeIdentities implements SecureIdentities {
  FakeIdentities(this.me, this.book);
  final String me;

  /// name → number of every phone in the test — what the test knows, not
  /// anything a phone holds: a phone knows only its own key.
  final Map<String, String> book;

  /// name → the label their key is made from, when the authority gave them
  /// a new one (default: the name).
  final Map<String, String> keys = {};

  /// Our certificate's generation (raised for a "lost phone"), and whether
  /// the authority signed it.
  int gen = 0;
  bool trusted = true;

  /// The generation a member's certificate is at (default 0).
  final Map<String, int> gens = {};

  String _key(String name) => keys[name] ?? name;

  String _certKid(String name, int g) => _hex(_kid('$name#$g'));

  OwnIdentity get _ownCert {
    final cert = fakeCert(me, book[me]!, gen: gen, ok: trusted);
    return OwnIdentity(
      identity: SmsIdentity(
        secret: _kid(_key(me)),
        publicKey: cert,
        keyId: fakeCertInfo(cert).keyId,
      ),
      number: book[me]!,
      cert: cert,
    );
  }

  SecurePeer certPeer(String name) => SecurePeer(
    name: name,
    phone: book[name]!,
    keyId: _certKid(name, gens[name] ?? 0),
    own: _ownCert,
  );

  /// A colleague, with the key id their certificate will carry.
  SecurePeer peer(String name) => certPeer(name);

  @override
  Future<OwnIdentity?> ownCert() async => _ownCert;

  /// As the real one: any mobile but our own, over our certificate, with no
  /// key id until the holder answers.
  @override
  Future<SecurePeer?> forNumber(String phone, {String? name}) async {
    if (phone == book[me] || !phone.startsWith('09')) return null;
    return SecurePeer(
      name: name ?? phone,
      phone: phone,
      keyId: '',
      own: _ownCert,
    );
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  @override
  Future<List<OwnIdentity>> own() async => [_ownCert];

  @override
  Future<OwnIdentity?> ownByKeyId(String keyId) async {
    for (final o in await own()) {
      if (o.keyId == keyId) return o;
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

  /// Every tracking id handed to the radio, in order.
  final List<String> tracking = [];
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
    air.tracking.add(trackingId);
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
      crypto = FakeCrypto(seed),
      hidden = FakeHidden() {
    store = SecureMessageStore(database: () => db);
    air.queues[number] = queue;
    groups = SecureGroupStore(database: () => db);
    messenger = SecureMessenger(
      store: store,
      groups: groups,
      queue: queue,
      identities: identities,
      crypto: crypto,
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
  final FakeCrypto crypto;
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
    'a lost request does not deadlock the crossed one that follows',
    () async {
      // Seen on two phones (1405/07/14): Ali's request never reached Sara;
      // minutes later Sara asked on her own. Ali wins the tie-break and used
      // to drop hers silently, waiting for an answer to a request she never
      // had — nothing moved for 24 hours.
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.sendText(book['sara']!, 'از علی');
      air.inFlight.clear(); // Ali's INIT is lost
      air.clock += SecureMessenger.crossedGrace.inMilliseconds + 1000;
      await sara.messenger.startConversation(sara.identities.peer('ali'));
      await sara.messenger.sendText(book['ali']!, 'از سارا');
      await settle();
      expect((await ali.thread(book['sara']!)).map((m) => m.body).toSet(), {
        'از علی',
        'از سارا',
      });
      expect((await sara.thread(book['ali']!)).map((m) => m.body).toSet(), {
        'از علی',
        'از سارا',
      });
      expect(
        (await ali.store.sessions(book['sara']!)).where((s) => s.pending),
        isEmpty,
      );
      expect(
        (await sara.store.sessions(book['ali']!)).where((s) => s.pending),
        isEmpty,
      );
    },
  );

  test('a request delivered again is never answered again', () async {
    // A replay — the radio delivering it twice, or anyone resending a
    // captured one, from any number — used to be answered whenever its
    // session had been pruned: a new session only Sara held, and her next
    // messages went out on it, unreadable to Ali.
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'یک');
    final request = air.inFlight.single;
    await settle();
    final before = await sara.store.sessions(book['ali']!);

    // Long after, and after the session it made has gone.
    air.clock += const Duration(days: 30).inMilliseconds;
    await sara.store.db.delete('sm_sessions');
    for (final s in before) {
      await sara.store.saveSession(s);
    }
    await sara.store.deleteSession(book['ali']!, before.last.sid);
    for (final from in [request.from, '09120000000']) {
      sara.queue.add(from, request.wire, air.clock++);
      await sara.messenger.drain();
    }
    expect(air.inFlight, isEmpty); // no answer went out
    expect(
      (await sara.store.sessions(book['ali']!)).map((s) => s.sid),
      before.map((s) => s.sid).where((sid) => sid != before.last.sid),
    );

    // The conversation goes on as it was.
    await sara.messenger.sendText(book['ali']!, 'دو');
    await settle();
    expect((await ali.thread(book['sara']!)).map((m) => m.body), ['یک', 'دو']);
  });

  test('a lost request is asked again on the next send', () async {
    await ali.messenger.startConversation(ali.identities.peer('sara'));
    await ali.messenger.sendText(book['sara']!, 'یک');
    air.inFlight.clear(); // lost
    await ali.messenger.sendText(book['sara']!, 'دو');
    expect(air.inFlight, isEmpty); // too soon to ask again
    air.clock += SecureMessenger.pendingTimeout.inMilliseconds + 1000;
    await ali.messenger.sendText(book['sara']!, 'سه');
    expect(air.inFlight, hasLength(1)); // a fresh INIT
    await settle();
    expect((await sara.thread(book['ali']!)).map((m) => m.body), [
      'یک',
      'دو',
      'سه',
    ]);
  });

  group('a channel that does not come is never silent', () {
    final saraNumber = book['sara']!;

    test(
      'a request the radio could not take is marked; «دوباره تلاش» sends one',
      () async {
        await ali.messenger.startConversation(ali.identities.peer('sara'));
        air.failNext = true; // no service for the request
        await ali.messenger.sendText(saraNumber, 'یک');
        expect(air.inFlight, isEmpty);
        var c = await ali.store.channelInfo(saraNumber);
        expect(c.requestFailed, isTrue);
        expect(c.established, isFalse);

        await ali.messenger.retryChannel(saraNumber);
        expect(air.inFlight, hasLength(1)); // a fresh request, at once
        c = await ali.store.channelInfo(saraNumber);
        expect(c.requestFailed, isFalse);
        await settle();
        expect((await sara.thread(book['ali']!)).map((m) => m.body), ['یک']);
        expect((await ali.store.channelInfo(saraNumber)).established, isTrue);
      },
    );

    test(
      'the radio\'s report on the request is what the screen shows',
      () async {
        await ali.messenger.startConversation(ali.identities.peer('sara'));
        await ali.messenger.sendText(saraNumber, 'یک');
        final id = air.tracking.single;
        expect(id, startsWith('cs:$saraNumber:'));
        await ali.messenger.onStatus(id, 'failed');
        expect((await ali.store.channelInfo(saraNumber)).requestFailed, isTrue);
        await ali.messenger.onStatus(id, 'sent');
        expect(
          (await ali.store.channelInfo(saraNumber)).requestFailed,
          isFalse,
        );
      },
    );

    test(
      'an unanswered request is asked again at once on «دوباره تلاش»',
      () async {
        await ali.messenger.startConversation(ali.identities.peer('sara'));
        await ali.messenger.sendText(saraNumber, 'یک');
        final first = await ali.store.channelInfo(saraNumber);
        expect(first.pendingSince, isNotNull);
        air.inFlight.clear(); // lost, or Sara's phone was off
        await ali.messenger.retryChannel(saraNumber);
        expect(air.inFlight, hasLength(1)); // not waiting for pendingTimeout
        await settle();
        expect((await sara.thread(book['ali']!)).map((m) => m.body), ['یک']);
      },
    );

    test('«دوباره تلاش» on a channel that is up does nothing', () async {
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.sendText(saraNumber, 'یک');
      await settle();
      final before = air.tracking.length;
      await ali.messenger.retryChannel(saraNumber);
      expect(air.inFlight, isEmpty);
      expect(air.tracking.length, before);
    });

    test(
      'a lost upgrade offer is offered again once the peer writes',
      () async {
        await ali.messenger.startConversation(ali.identities.peer('sara'));
        await ali.messenger.sendText(saraNumber, 'یک');
        air.deliver();
        await sara.messenger.drain();
        air.deliver();
        await ali.messenger.drain();
        expect(air.tracking.last, startsWith('cs:$saraNumber:')); // the offer
        air.inFlight.clear(); // lost on the way
        // Sara writes a few minutes later, on the classical session.
        air.clock +=
            SecureMessenger.upgradeRetryWhenHeard.inMilliseconds + 1000;
        await sara.messenger.sendText(book['ali']!, 'سلام');
        final offers = air.tracking.where((t) => t.startsWith('cs:')).length;
        air.deliver();
        await ali.messenger.drain();
        // Ali, hearing her, offers the upgrade again without waiting 30 min.
        expect(
          air.tracking.where((t) => t.startsWith('cs:')).length,
          offers + 1,
        );
        await settle();
        expect((await ali.store.channelInfo(saraNumber)).upgraded, isTrue);
      },
    );

    test(
      'a late old offer does not undo the upgrade (found on the phones)',
      () async {
        // Samsung ↔ Xiaomi, 1405/07/29: the first offer was held up, the
        // second was answered, then the first arrived and its answer replaced
        // the standby session the offerer went on to use — every message after
        // the upgrade was unreadable.
        await ali.messenger.startConversation(ali.identities.peer('sara'));
        await ali.messenger.sendText(saraNumber, 'یک');
        air.deliver();
        await sara.messenger.drain();
        air.deliver();
        await ali.messenger.drain();
        final held = List.of(air.inFlight); // the message, then offer 1
        air.inFlight.clear();
        expect(held, hasLength(2));
        air.inFlight.add(held.first);
        air.deliver();
        await sara.messenger.drain();
        // Sara writes later; Ali offers again (offer 2).
        air.clock +=
            SecureMessenger.upgradeRetryWhenHeard.inMilliseconds + 1000;
        await sara.messenger.sendText(book['ali']!, 'سلام');
        air.deliver();
        await ali.messenger.drain();
        // Offer 2 reaches Sara first, then the old offer 1.
        air.inFlight.add(held.last);
        air.deliver();
        await sara.messenger.drain();
        await settle();
        expect((await ali.store.channelInfo(saraNumber)).upgraded, isTrue);
        await ali.messenger.sendText(saraNumber, 'بعد از ارتقا');
        await settle();
        expect(
          (await sara.thread(book['ali']!)).map((m) => m.body),
          contains('بعد از ارتقا'),
        );
        await sara.messenger.sendText(book['ali']!, 'رسید');
        await settle();
        expect(
          (await ali.thread(saraNumber)).map((m) => m.body),
          contains('رسید'),
        );
      },
    );

    test('a failed upgrade offer is offered again, unseen', () async {
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.sendText(saraNumber, 'یک');
      // The request and its answer only; the upgrade offer is held back.
      air.deliver();
      await sara.messenger.drain();
      air.deliver();
      await ali.messenger.drain();
      var c = await ali.store.channelInfo(saraNumber);
      expect(c.established, isTrue);
      expect(c.canOfferUpgrade, isTrue);
      expect(c.upgraded, isFalse);
      final offer = air.tracking.last;
      expect(offer, startsWith('cs:$saraNumber:'));
      air.inFlight.clear(); // the offer never arrives
      await ali.messenger.onStatus(offer, 'failed');
      c = await ali.store.channelInfo(saraNumber);
      expect(c.upgradeOfferFailed, isTrue);

      // The next flush offers it again, without waiting for upgradeRetry.
      await ali.messenger.flush(saraNumber);
      expect(
        (await ali.store.channelInfo(saraNumber)).upgradeOfferFailed,
        isFalse,
      );
      expect(air.inFlight, isNotEmpty);
      await settle();
      expect((await ali.store.channelInfo(saraNumber)).upgraded, isTrue);
    });
  });

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

  group('a key the authority replaced (issuance panel)', () {
    /// Sara's new phone: her SIM, a fresh secure section, and the new key
    /// from the file the panel issued after «گوشی گم شد» (generation 1).
    Future<Phone> newPhone() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await SecureStore.createSchemaForTest(db);
      addTearDown(db.close);
      return Phone('sara', book['sara']!, db, air, book, 700)
        ..identities.keys['sara'] = 'saranew'
        ..identities.gen = 1;
    }

    Future<void> settleWith(Phone a, Phone b) async {
      for (var i = 0; i < 10 && air.inFlight.isNotEmpty; i++) {
        air.deliver();
        await a.messenger.drain();
        await b.messenger.drain();
      }
    }

    test(
      '«گوشی گم شد»: once the new phone is heard, the lost one is not',
      () async {
        await ali.messenger.startConversation(ali.identities.peer('sara'));
        await ali.messenger.sendText(book['sara']!, 'یک');
        await settle();
        expect((await sara.thread(book['ali']!)).single.body, 'یک');
        final lost = sara;

        // The new phone writes first: its request carries generation 1.
        final saraNew = await newPhone();
        await saraNew.messenger.startConversation(
          saraNew.identities.peer('ali'),
        );
        await saraNew.messenger.sendText(book['ali']!, 'از گوشی تازه');
        await settleWith(ali, saraNew);
        final conversation = (await ali.store.conversation(book['sara']!))!;
        expect(conversation.peerGeneration, 1);
        expect(conversation.peerKeyId, FakeIdentities._hex(_kid('sara#1')));

        // The lost phone writes over its old session: Ali no longer reads it.
        await lost.messenger.sendText(book['ali']!, 'از گوشی گم‌شده');
        air.deliver();
        await ali.messenger.drain();
        expect((await ali.thread(book['sara']!)).map((m) => m.body), [
          'یک',
          'از گوشی تازه',
        ]);

        // Ali writes on: the new phone reads it.
        await ali.messenger.sendText(book['sara']!, 'دو');
        await settleWith(ali, saraNew);
        expect((await saraNew.thread(book['ali']!)).map((m) => m.body), [
          'از گوشی تازه',
          'دو',
        ]);
      },
    );

    test('our own key replaced: the conversation moves to it', () async {
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.sendText(book['sara']!, 'یک');
      await settle();
      // Ali's new key file (generation 1) is imported on his phone.
      ali.identities
        ..keys['ali'] = 'alinew'
        ..gen = 1;
      await ali.messenger.sendText(book['sara']!, 'دو');
      final request = _unwire(air.inFlight.single.wire);
      expect(request['t'], 'init');
      expect(fakeCertInfo(_bytes(request['cert'] as String)).generation, 1);
      await settle();
      expect((await sara.thread(book['ali']!)).map((m) => m.body), [
        'یک',
        'دو',
      ]);
      expect((await sara.store.conversation(book['ali']!))!.peerGeneration, 1);
    });

    test('nothing changes while the keys are current', () async {
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.sendText(book['sara']!, 'یک');
      await settle();
      // The newest sendable session is the one messages go on.
      final before = (await ali.store.sessions(
        book['sara']!,
      )).where((s) => s.sendable).first;
      expect(before.kind, SessionKind.pq);
      await ali.messenger.sendText(book['sara']!, 'دو');
      expect(_unwire(air.inFlight.single.wire)['t'], 'message');
      await settle();
      final after = (await ali.store.sessions(
        book['sara']!,
      )).where((s) => s.sendable).first;
      expect(after.sid, before.sid);
    });
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
    // A hidden contact's plain SMS live in their own thread, never in the
    // encrypted conversation with the same number.
    const reza = '09125555555';
    final rezaPlain = SecureMessenger.plainThread(reza);

    test(
      'a plain SMS from a hidden contact is stored once, named, keyless',
      () async {
        ali.hidden.names[reza] = 'رضا';
        ali.hidden.add(reza, 'سلام، کجایی؟', 5000);
        await ali.messenger.drain();
        // Kotlin parked it again (the delete failed): still one message.
        ali.hidden.add(reza, 'سلام، کجایی؟', 5000);
        await ali.messenger.drain();

        final c = (await ali.store.conversation(rezaPlain))!;
        expect(c.name, 'رضا');
        expect(c.encrypted, isFalse);
        expect(c.unread, 1);
        final m = (await ali.thread(rezaPlain)).single;
        expect(m.plain, isTrue);
        expect(m.outgoing, isFalse);
        expect(m.body, 'سلام، کجایی؟');
        expect(await ali.store.conversation(reza), isNull);
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

    test('plain and encrypted chats with one number are never mixed', () async {
      ali.hidden.names[book['sara']!] = 'سارا';
      // Sara's plain SMS first, in her plain thread…
      ali.hidden.add(book['sara']!, 'پیامک عادی', 5000);
      await ali.messenger.drain();
      // …then an encrypted conversation with her.
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.sendText(book['sara']!, 'رمزی');
      await settle();
      final plain = await ali.thread(
        SecureMessenger.plainThread(book['sara']!),
      );
      final encrypted = await ali.thread(book['sara']!);
      expect(plain.map((m) => m.body), ['پیامک عادی']);
      expect(plain.every((m) => m.plain), isTrue);
      expect(encrypted.map((m) => m.body), ['رمزی']);
      expect(encrypted.any((m) => m.plain), isFalse);
      expect(
        (await ali.store.conversation(
          SecureMessenger.plainThread(book['sara']!),
        ))!.encrypted,
        isFalse,
      );
      expect((await ali.store.conversation(book['sara']!))!.encrypted, isTrue);
      // Plain text cannot be sent into the encrypted conversation.
      await ali.messenger.sendPlain(book['sara']!, 'نه');
      expect((await ali.thread(book['sara']!)).map((m) => m.body), ['رمزی']);
    });

    test(
      'a keyless conversation sends plain SMS at once, never a handshake',
      () async {
        final thread = await ali.messenger.startPlainConversation(reza, 'رضا');
        expect(thread, rezaPlain);
        await ali.messenger.sendPlain(thread, 'بدون رمز');
        final sent = air.inFlight.single;
        expect(sent.wire, 'بدون رمز');
        expect(sent.to, reza);
        final m = (await ali.thread(thread)).single;
        expect(m.plain, isTrue);
        expect(m.status, SecureMessageStatus.sent);
        await ali.messenger.flush(thread); // nothing to encrypt
        expect(air.inFlight, hasLength(1));
        expect(await ali.store.sessions(thread), isEmpty);
        expect(await ali.store.sessions(reza), isEmpty);
      },
    );

    test('a failed plain SMS is retried as plain', () async {
      final thread = await ali.messenger.startPlainConversation(reza, 'رضا');
      air.failNext = true;
      await ali.messenger.sendPlain(thread, 'دوباره');
      final failed = (await ali.thread(thread)).single;
      expect(failed.status, SecureMessageStatus.failed);
      await ali.messenger.retry(failed.id);
      expect(air.inFlight.single.wire, 'دوباره');
      expect(air.inFlight.single.to, reza);
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
      await ali.messenger.importPlainHistory(reza, 'رضا', history);
      await ali.messenger.importPlainHistory(reza, 'رضا', history);
      final thread = await ali.thread(rezaPlain);
      expect(thread.map((m) => m.body), ['قدیمی ۱', 'قدیمی ۲']);
      expect(thread.every((m) => m.plain), isTrue);
      expect(thread.first.seenAt, isNotNull);
      final c = (await ali.store.conversation(rezaPlain))!;
      expect(c.unread, 0);
      expect(c.lastAt, 20);
    });

    test(
      'a scheduled SMS sent to a hidden number lands as ours, read',
      () async {
        ali.hidden.names[reza] = 'رضا';
        ali.hidden.add(reza, 'زمان‌بندی‌شده', 7000, extra: {'outgoing': true});
        await ali.messenger.drain();
        final m = (await ali.thread(rezaPlain)).single;
        expect(m.outgoing, isTrue);
        expect(m.plain, isTrue);
        expect(m.status, SecureMessageStatus.sent);
        expect((await ali.store.conversation(rezaPlain))!.unread, 0);
      },
    );

    test(
      'an operator notice naming a hidden number joins that conversation',
      () async {
        ali.hidden.names[reza] = 'رضا';
        ali.hidden.add(
          'MCI',
          'تماس از 09125555555',
          8000,
          extra: {'about': reza},
        );
        await ali.messenger.drain();
        expect(await ali.store.conversation('MCI'), isNull);
        final m = (await ali.thread(rezaPlain)).single;
        expect(m.body, 'پیامک MCI: تماس از 09125555555');
        expect(m.outgoing, isFalse);
        expect((await ali.store.conversation(rezaPlain))!.name, 'رضا');
      },
    );

    test('renaming a hidden contact renames both of their chats', () async {
      await ali.messenger.startConversation(ali.identities.peer('sara'));
      await ali.messenger.startPlainConversation(book['sara']!, 'سارا');
      await ali.messenger.rename([book['sara']!], 'سارا کریمی');
      expect((await ali.store.conversation(book['sara']!))!.name, 'سارا کریمی');
      final plain = (await ali.store.conversation(
        SecureMessenger.plainThread(book['sara']!),
      ))!;
      expect(plain.name, 'سارا کریمی');
      expect(plain.encrypted, isFalse);
      expect((await ali.store.conversation(book['sara']!))!.encrypted, isTrue);
    });
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

  // ── Member certificates (`CertHandshake`) and the upgrade (`Upgrade`) ──────
  group('certificates', () {
    Future<List<StoredSession>> sessionsOf(Phone p, String peer) =>
        p.store.sessions(book[peer]!);

    Future<Database> openDb() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await SecureStore.createSchemaForTest(db);
      return db;
    }

    test(
      'a first message goes over a certificate request, then the session turns post-quantum',
      () async {
        await ali.messenger.startConversation(ali.identities.certPeer('sara'));
        await ali.messenger.sendText(book['sara']!, 'سلام');
        // Ali never had Sara's key: the request carries his certificate.
        final request = _unwire(air.inFlight.single.wire);
        expect(request['t'], 'init');
        expect(request['cert'], isNotNull);
        // Not «پساکوانتومی» yet: X25519 only until the upgrade lands.
        expect(
          (await ali.store.conversation(book['sara']!))!.quantumSafe,
          isFalse,
        );

        await settle();
        expect((await sara.thread(book['ali']!)).single.body, 'سلام');
        expect(
          (await ali.thread(book['sara']!)).single.status,
          SecureMessageStatus.sent,
        );
        // The upgrade ran behind the message, and both sides use it.
        final aliSessions = await sessionsOf(ali, 'sara');
        final saraSessions = await sessionsOf(sara, 'ali');
        expect(aliSessions.first.kind, SessionKind.pq);
        expect(saraSessions.first.kind, SessionKind.pq);
        expect(aliSessions.first.sid, saraSessions.first.sid);
        expect(
          (await ali.store.conversation(book['sara']!))!.quantumSafe,
          isTrue,
        );
        expect(
          (await sara.store.conversations())
              .singleWhere((c) => c.phone == book['ali'])
              .quantumSafe,
          isTrue,
        );

        await sara.messenger.sendText(book['ali']!, 'علیک سلام');
        expect(
          _unwire(air.inFlight.single.wire)['sid'],
          saraSessions.first.sid,
        );
        await settle();
        expect(
          (await ali.thread(book['sara']!)).map((m) => m.body),
          contains('علیک سلام'),
        );
        // The peer key comes from the answer.
        final c = (await ali.store.conversation(book['sara']!))!;
        expect(c.encrypted, isTrue);
        expect(c.peerKeyId, isNotEmpty);
        expect(c.peerGeneration, 0);
      },
    );

    test('any number is reached by number alone', () async {
      // Nima's key file was issued after everyone else's, and nobody else
      // got anything new: there is no list of members anywhere.
      const nimaNumber = '09124444444';
      final nima = Phone('nima', nimaNumber, await openDb(), air, {
        ...book,
        'nima': nimaNumber,
      }, 400);
      addTearDown(nima.db.close);

      final way = (await ali.identities.forNumber(nimaNumber))!;
      expect(way.keyId, isEmpty);
      await ali.messenger.startConversation(way);
      await ali.messenger.sendText(nimaNumber, 'خوش آمدی');
      for (var i = 0; i < 10 && air.inFlight.isNotEmpty; i++) {
        air.deliver();
        await ali.messenger.drain();
        await nima.messenger.drain();
      }
      expect((await nima.thread(book['ali']!)).single.body, 'خوش آمدی');
      // No key file names anybody: the request is known by its number.
      expect((await nima.store.conversation(book['ali']!))!.name, book['ali']);
      // Who answered is known now.
      expect((await ali.store.conversation(nimaNumber))!.peerKeyId, isNotEmpty);
      expect((await ali.store.sessions(nimaNumber)).first.kind, SessionKind.pq);
    });

    test('a request the authority did not sign is not answered', () async {
      sara.identities.trusted = false;
      await sara.messenger.startConversation(sara.identities.certPeer('ali'));
      await sara.messenger.sendText(book['ali']!, 'جعلی');
      air.deliver();
      await ali.messenger.drain();
      expect(air.inFlight, isEmpty);
      expect(await ali.store.conversation(book['sara']!), isNull);
    });

    test(
      'a lost phone\'s older certificate is refused once a newer one is seen',
      () async {
        await ali.messenger.startConversation(ali.identities.certPeer('sara'));
        await ali.messenger.sendText(book['sara']!, 'یک');
        await settle();
        final lostPhonesRequest = ali.crypto.certInits.first;

        // «گوشی گم شد»: Ali's new key file is generation 1. His conversation
        // moves to it and asks again; Sara follows.
        ali.identities.gen = 1;
        sara.identities.gens['ali'] = 1;
        await ali.messenger.sendText(book['sara']!, 'دو');
        await settle();
        expect(
          (await sara.thread(book['ali']!)).map((m) => m.body),
          containsAll(['یک', 'دو']),
        );
        expect(
          (await sara.store.conversation(book['ali']!))!.peerGeneration,
          1,
        );

        // The lost phone asks again with its old certificate: no answer.
        sara.queue.add(book['ali']!, lostPhonesRequest, air.clock++);
        await sara.messenger.drain();
        expect(air.inFlight, isEmpty);
      },
    );

    test(
      'a lost upgrade answer leaves both on the classical session until the offer is repeated',
      () async {
        await ali.messenger.startConversation(ali.identities.certPeer('sara'));
        await ali.messenger.sendText(book['sara']!, 'سلام');
        for (var i = 0; i < 10 && air.inFlight.isNotEmpty; i++) {
          air.inFlight.removeWhere(
            (p) => _unwire(p.wire)['kind'] == 'pqAccept',
          );
          air.deliver();
          await ali.messenger.drain();
          await sara.messenger.drain();
        }
        expect(
          (await sessionsOf(ali, 'sara')).first.kind,
          SessionKind.certInitiated,
        );
        expect(
          (await sessionsOf(sara, 'ali')).map((s) => s.kind),
          contains(SessionKind.pqStandby),
        );

        // Sara does not write on a session Ali never got.
        await sara.messenger.sendText(book['ali']!, 'هنوز کلاسیک');
        await settle();
        expect(
          (await ali.thread(book['sara']!)).map((m) => m.body),
          contains('هنوز کلاسیک'),
        );
        expect(
          (await sessionsOf(ali, 'sara')).first.kind,
          SessionKind.certInitiated,
        );

        // Half an hour on, Ali's next flush offers again, and this time it works.
        air.clock += SecureMessenger.upgradeRetry.inMilliseconds + 1;
        await ali.messenger.flush(book['sara']!);
        await settle();
        expect((await sessionsOf(ali, 'sara')).first.kind, SessionKind.pq);
        expect((await sessionsOf(sara, 'ali')).first.kind, SessionKind.pq);
        await ali.messenger.sendText(book['sara']!, 'حالا کوانتومی');
        await settle();
        expect(
          (await sara.thread(book['ali']!)).map((m) => m.body),
          contains('حالا کوانتومی'),
        );
      },
    );
  });
}
