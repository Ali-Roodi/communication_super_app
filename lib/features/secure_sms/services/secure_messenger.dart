import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_group_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

import '../repositories/secure_queue_repository.dart';
import 'hidden_sms_source.dart';
import 'secure_identities.dart';
import 'secure_sms_sender.dart';

/// What processing one received packet came to.
enum _Outcome {
  /// Handled, or not ours / not usable — either way, never look at it again.
  done,

  /// Cannot be handled yet (a message whose session's handshake has not been
  /// processed): keep it and try again after the next packet.
  wait,
}

/// The encrypted-SMS engine: turns received packets into conversations and
/// outgoing text into packets, over the stateless crypto (`SmsCryptoService`)
/// and the secure section's storage (`SecureMessageStore`).
///
/// **Every operation runs one at a time** ([_serial]): a drain and a send
/// racing on one session would both advance the same ratchet from the same
/// state, and one of them would reuse a message key.
///
/// **A session's new state is stored before its SMS is sent.** If the app
/// dies between the two, the peer misses a message; the other order would
/// send the next message under a key already used.
///
/// Handshakes are automatic and invisible: the first message to someone
/// sends a session request (about ten SMS parts) and waits in the conversation
/// as «در انتظار برقراری کانال امن» until the answer arrives.
class SecureMessenger {
  SecureMessenger({
    SecureMessageStore? store,
    SecureGroupStore? groups,
    SecureQueueRepository? queue,
    SecureIdentities? identities,
    SmsCryptoService crypto = const SmsCryptoService(),
    SecureSmsSender? sender,
    HiddenSmsSource? hidden,
    int Function()? clock,
    String Function()? newId,
    bool? coverAllowed,
  }) : _coverAllowed = coverAllowed ?? kOrganizationBuild,
       _store = store ?? SecureMessageStore(),
       _groups = groups ?? SecureGroupStore(),
       _hidden = hidden,
       _queue = queue ?? SecureQueueRepository(),
       _identities = identities ?? SecureIdentities(),
       _crypto = crypto,
       _sender = sender ?? NativeSecureSmsSender(),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _newId = newId ?? (() => const Uuid().v4());

  final SecureMessageStore _store;

  /// Encrypted groups (matrix row 14): a group message is sealed once per
  /// member, over that member's own session.
  final SecureGroupStore _groups;
  final SecureQueueRepository _queue;
  final SecureIdentities _identities;
  final SmsCryptoService _crypto;
  final SecureSmsSender _sender;

  /// SMS from hidden contacts, sealed by Kotlin (phase G); null in tests
  /// that do not need it.
  final HiddenSmsSource? _hidden;
  final int Function() _clock;
  final String Function() _newId;

  /// A packet that could not be used for this long, or this many tries, is
  /// dropped: its handshake is not coming.
  static const maxWait = Duration(days: 7);
  static const maxAttempts = 50;

  /// Our session request is re-sent (on the next send) when unanswered this
  /// long. It was 24 hours: a request is ten SMS, one lost part loses all of
  /// it, and the conversation then sat dead for a day (1405/07/14).
  static const pendingTimeout = Duration(minutes: 15);

  /// Crossed requests: when the peer's arrives while ours has waited longer
  /// than this, ours is taken as lost — the peer sent its own because it never
  /// saw ours — and is sent again even though it wins the tie-break.
  static const crossedGrace = Duration(minutes: 3);

  /// `secure_meta` key: whether «دیده شد» receipts are sent (default on).
  static const sendSeenKey = 'send_seen_receipts';

  /// `secure_meta` key: «متن پوششی» (row 31, organization edition) —
  /// `fa`, `en`, or absent for plain `#E:`.
  static const coverKey = 'cover_text';

  /// Whether this build may send cover text at all.
  final bool _coverAllowed;

  final StreamController<String?> _changes = StreamController.broadcast();

  /// A conversation changed (its number), or the list did (null).
  Stream<String?> get changes => _changes.stream;

  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Forget cached identities (the key bank changed or the section closed).
  void reset() => _identities.reset();

  Future<void> dispose() => _changes.close();

  void _changed(String? phone) {
    if (!_changes.isClosed) _changes.add(phone);
  }

  // ── Receiving ────────────────────────────────────────────────────────────

  /// Takes everything the native receivers parked and processes it.
  Future<void> drain() => _serial(() async {
    // The key bank may have changed since the last drain (a key file
    // imported, a group added): identities are looked up afresh.
    _identities.reset();
    await _takeHidden();
    final queued = await _queue.all();
    if (queued.isNotEmpty) {
      await _store.addToInbox([
        for (final q in queued)
          InboxPacket(
            id: 0,
            address: q.address,
            body: q.body,
            timestamp: q.timestamp,
            attempts: 0,
          ),
      ], _clock());
      // Only once the copy is committed: a crash in between leaves the rows
      // in both places, and the inbox's UNIQUE (address, body) absorbs that.
      await _queue.delete(queued.map((q) => q.id));
    }
    await _processInbox();
  });

  /// SMS from hidden contacts: an encrypted one joins the packet inbox like
  /// any other, a plain one is stored as it is.
  Future<void> _takeHidden() async {
    final source = _hidden;
    if (source == null) return;
    final entries = await source.take();
    if (entries.isEmpty) return;
    final packets = <InboxPacket>[];
    for (final e in entries) {
      final r = e.record;
      final address = r?['address'];
      final body = r?['body'];
      final timestamp = r?['timestamp'];
      if (address is! String || body is! String || timestamp is! int) continue;
      final about = r?['about'];
      if (about is String && about.isNotEmpty) {
        // An operator's notice naming a hidden contact («تماس از …»): kept
        // in that contact's conversation, with who sent it.
        await _receivePlain(about, 'پیامک $address: $body', timestamp);
      } else if (r?['outgoing'] == true) {
        // A scheduled message that went out to a number hidden since.
        await _receivePlain(address, body, timestamp, outgoing: true);
      } else if (SmsCryptoService.looksEncrypted(body)) {
        packets.add(
          InboxPacket(
            id: 0,
            address: address,
            body: body,
            timestamp: timestamp,
            attempts: 0,
          ),
        );
      } else {
        await _receivePlain(address, body, timestamp);
      }
    }
    if (packets.isNotEmpty) await _store.addToInbox(packets, _clock());
    // Only once stored: a crash in between re-reads them, and both stores
    // deduplicate.
    await source.remove(entries.map((e) => e.id));
  }

  Future<void> _receivePlain(
    String address,
    String body,
    int timestamp, {
    bool outgoing = false,
  }) async {
    final phone = await _crypto.canonicalPhone(address) ?? address;
    if (await _store.hasPlain(
      phone,
      outgoing: outgoing,
      body: body,
      timestamp: timestamp,
    )) {
      return;
    }
    if (await _store.conversation(phone) == null) {
      await _store.ensurePlainConversation(
        phone: phone,
        name: await _hidden?.nameFor(phone) ?? phone,
        now: timestamp,
      );
    }
    await _store.addMessage(
      SecureMessage(
        id: _newId(),
        phone: phone,
        outgoing: outgoing,
        body: body,
        timestamp: timestamp,
        status: outgoing
            ? SecureMessageStatus.sent
            : SecureMessageStatus.received,
        plain: true,
      ),
    );
    await _store.touchConversation(phone, timestamp, unread: !outgoing);
    _changed(phone);
  }

  Future<void> _processInbox() async {
    // One pass may unblock another (a RESPONSE makes the messages behind it
    // readable), so passes repeat while they make progress.
    var progress = true;
    while (progress) {
      progress = false;
      for (final packet in await _store.inbox()) {
        final outcome = await _process(packet);
        final expired =
            _clock() - packet.timestamp > maxWait.inMilliseconds ||
            packet.attempts + 1 >= maxAttempts;
        if (outcome == _Outcome.done || expired) {
          await _store.removeFromInbox(packet.id);
          if (outcome == _Outcome.done) progress = true;
        } else {
          await _store.retryLater(packet.id);
        }
      }
    }
  }

  Future<_Outcome> _process(InboxPacket packet) async {
    final info = await _crypto.inspect(packet.body);
    if (info == null) return _Outcome.done;
    final from = await _crypto.canonicalPhone(packet.address) ?? packet.address;
    // Dual-SIM phones answer from whichever SIM sends SMS, which need not be
    // the number the key bank lists: who a packet belongs to is decided by
    // its key / session, and only then by the number it came from.
    final phone = await _owner(from, info);
    try {
      return switch (info.type) {
        SmsPacketType.init => await _onInit(phone, packet, info),
        SmsPacketType.response => await _onResponse(phone, packet, info),
        SmsPacketType.message => await _onMessage(phone, packet, info),
      };
    } on SmsCryptoException catch (e) {
      // Not for us, forged, altered, or from a newer build: nothing to keep.
      debugPrint('Encrypted SMS dropped: ${e.failure.name}');
      return _Outcome.done;
    }
  }

  /// The conversation a packet from [from] belongs to.
  Future<String> _owner(String from, SmsPacketInfo info) async {
    switch (info.type) {
      case SmsPacketType.init:
        // A request from a key we already talk to, over another SIM: the
        // same conversation, not a second one.
        final kid = info.senderKid;
        if (kid == null) return from;
        final known = await _store.phoneForPeerKey(keyHex(kid));
        return known ?? from;
      case SmsPacketType.response:
        if ((await _store.sessions(
          from,
        )).any((s) => s.pending && s.sid == info.sid)) {
          return from;
        }
        final kid = info.senderKid;
        if (kid != null) {
          final known = await _store.phoneForPeerKey(keyHex(kid));
          if (known != null) return known;
        }
        final pending = await _store.phonesWithSession(info.sid, pending: true);
        return pending.length == 1 ? pending.single : from;
      case SmsPacketType.message:
        if ((await _store.sessions(
          from,
        )).any((s) => !s.pending && s.sid == info.sid)) {
          return from;
        }
        final holders = await _store.phonesWithSession(info.sid);
        return holders.length == 1 ? holders.single : from;
    }
  }

  Future<_Outcome> _onInit(
    String phone,
    InboxPacket packet,
    SmsPacketInfo info,
  ) async {
    // Every way out without an answer says why in the log: a dropped request
    // stalls the conversation, and it used to leave no trace at all.
    final own = await _identities.ownByKeyId(keyHex(info.recipientKid!));
    if (own == null) {
      debugPrint('Session request dropped: not for a key this phone holds');
      return _Outcome.done;
    }
    final peer = await _identities.byKeyId(keyHex(info.senderKid!), phone);
    if (peer == null) {
      debugPrint('Session request dropped: sender not in the key bank');
      return _Outcome.done;
    }

    final sessions = await _store.sessions(phone);
    // The same request delivered twice: answered already.
    if (sessions.any((s) => s.sid == info.sid && !s.pending)) {
      debugPrint('Session request already answered');
      return _Outcome.done;
    }
    // Both sides asked at once. Each phone decides the same way from the two
    // key ids; the loser drops its own request and answers the other one.
    for (final mine in sessions.where((s) => s.pending)) {
      if (await _crypto.ownInitWins(own.identity.keyId, info.senderKid!)) {
        // The winner waits for its answer — unless its request is old: then
        // the peer asked because ours never reached it, nobody would answer
        // anybody, and the conversation deadlocked (two phones, 1405/07/14).
        // A fresh request goes out; the peer, now the one crossed, answers.
        if (_clock() - mine.createdAt > crossedGrace.inMilliseconds) {
          debugPrint(
            'Crossed session requests: ours went unanswered, asking again',
          );
          await _store.deleteSession(phone, mine.sid);
          final conversation = await _store.conversation(phone);
          if (conversation != null && conversation.encrypted) {
            await _handshakeIfNeeded(
              conversation,
              await _store.sessions(phone),
            );
          }
        } else {
          debugPrint(
            'Crossed session requests: ours wins, waiting for the answer',
          );
        }
        return _Outcome.done;
      }
      await _store.deleteSession(phone, mine.sid);
    }

    final answer = await _crypto.respond(
      secret: own.identity.secret,
      peer: peer.publicKey,
      text: packet.body,
    );
    final now = _clock();
    await _store.upsertConversation(
      phone: phone,
      // A hidden contact is called what the user named them.
      name: await _hidden?.nameFor(phone) ?? peer.name,
      peerKeyId: peer.keyId,
      peerPublic: peer.publicKey,
      ownKeyId: own.keyId,
      ownSource: own.source,
      now: now,
      // A session request alone lists nothing: it may be for a group, and
      // the first message in the pair lists the conversation.
      listed: false,
    );
    await _store.saveSession(
      StoredSession(
        phone: phone,
        sid: answer.sid!,
        pending: false,
        state: answer.state,
        createdAt: now,
      ),
    );
    await _store.pruneSessions(phone);
    await _sendQuietly(phone, answer.wire, 'hs-${_newId()}');
    debugPrint('Session request answered');
    _changed(null);
    await _flush(phone);
    return _Outcome.done;
  }

  Future<_Outcome> _onResponse(
    String phone,
    InboxPacket packet,
    SmsPacketInfo info,
  ) async {
    final sessions = await _store.sessions(phone);
    final pending = sessions
        .where((s) => s.pending && s.sid == info.sid)
        .firstOrNull;
    if (pending == null) return _Outcome.done; // not ours, or answered already
    final conversation = await _store.conversation(phone);
    if (conversation == null || !conversation.encrypted) return _Outcome.done;
    // An answer to a request made with keys since retired: start over.
    if (!await _keysCurrent(conversation)) {
      await _current(conversation);
      await _flush(phone);
      return _Outcome.done;
    }
    final own = await _identities.ownByKeyId(conversation.ownKeyId!);
    if (own == null) return _Outcome.done;
    final Uint8List session;
    try {
      session = await _crypto.complete(
        secret: own.identity.secret,
        peer: conversation.peerPublic!,
        pending: pending.state,
        text: packet.body,
      );
    } on SmsCryptoException catch (e) {
      // A forged or corrupted answer: keep waiting for the real one.
      debugPrint('Session answer refused: ${e.failure.name}');
      return _Outcome.done;
    }
    await _store.saveSession(
      StoredSession(
        phone: phone,
        sid: pending.sid,
        pending: false,
        state: session,
        createdAt: _clock(),
      ),
    );
    await _store.pruneSessions(phone);
    await _flush(phone);
    return _Outcome.done;
  }

  Future<_Outcome> _onMessage(
    String phone,
    InboxPacket packet,
    SmsPacketInfo info,
  ) async {
    // A session made with a key the authority has since replaced (a lost
    // phone's) is not read: the conversation moves to the current key and
    // the old sessions go — see [_current].
    final conversation = await _store.conversation(phone);
    if (conversation != null &&
        conversation.encrypted &&
        !await _keysCurrent(conversation)) {
      await _current(conversation);
      debugPrint('Encrypted SMS dropped: its session uses a retired key');
      return _Outcome.done;
    }
    final session = (await _store.sessions(
      phone,
    )).where((s) => !s.pending && s.sid == info.sid).firstOrNull;
    // Its session's handshake is not processed yet (the responder's first
    // message can overtake our copy of its RESPONSE).
    if (session == null) return _Outcome.wait;

    final SmsDecrypted opened;
    try {
      opened = await _crypto.decrypt(session: session.state, text: packet.body);
    } on SmsCryptoException catch (e) {
      if (e.failure == SmsCryptoFailure.duplicate) return _Outcome.done;
      rethrow;
    }
    // A group definition needs our key ids (to find ourselves in it) and
    // canonical numbers — read before the transaction: the key bank lives in
    // this same database.
    ({List<({String phone, String keyId})> members, bool includesMe})?
    definition;
    final groupInfo = opened.groupInfo;
    if (groupInfo != null) {
      final own = {for (final o in await _identities.own()) o.keyId};
      final members = <({String phone, String keyId})>[];
      var me = false;
      for (final m in groupInfo.members) {
        final kid = keyHex(m.keyId);
        if (own.contains(kid)) {
          me = true;
          continue;
        }
        final canonical = await _crypto.canonicalPhone(m.phone) ?? m.phone;
        // The creator is added by every receiver itself.
        if (canonical == phone) continue;
        members.add((phone: canonical, keyId: kid));
      }
      definition = (members: members, includesMe: me);
    }
    var groupChanged = false;
    await _store.db.transaction((txn) async {
      await _store.updateSessionState(txn, phone, session.sid, opened.session);
      switch (opened.kind) {
        case SmsPayloadKind.text when opened.groupId != null:
          final gid = keyHex(opened.groupId!);
          // Before its definition, if SMS arrived out of order.
          await _groups.ensurePlaceholder(txn, gid, packet.timestamp);
          await _groups.addIncoming(
            txn,
            SecureGroupMessage(
              id: _newId(),
              groupId: gid,
              sender: phone,
              body: opened.text!,
              timestamp: packet.timestamp,
              status: SecureMessageStatus.received,
              sid: opened.sid,
              counter: opened.counter,
              deleteAfterSeen: opened.deleteAfterSeen,
              ttl: opened.ttlSeconds,
            ),
          );
          await _groups.touch(gid, packet.timestamp, unread: true, txn: txn);
          groupChanged = true;
        case SmsPayloadKind.groupInfo:
          groupChanged = await _groups.applyInfo(
            txn,
            id: keyHex(groupInfo!.groupId),
            sender: phone,
            version: groupInfo.version,
            mode: SecureGroupMode.values[groupInfo.mode.index],
            name: groupInfo.name,
            members: definition!.members,
            includesMe: definition.includesMe,
            now: packet.timestamp,
          );
        case SmsPayloadKind.text:
          await _store.insertMessage(
            txn,
            SecureMessage(
              id: _newId(),
              phone: phone,
              outgoing: false,
              body: opened.text!,
              timestamp: packet.timestamp,
              status: SecureMessageStatus.received,
              sid: opened.sid,
              counter: opened.counter,
              deleteAfterSeen: opened.deleteAfterSeen,
              ttl: opened.ttlSeconds,
            ),
          );
          await txn.rawUpdate(
            'UPDATE sm_conversations SET last_at = MAX(last_at, ?), '
            'unread = unread + 1 WHERE phone = ?',
            [packet.timestamp, phone],
          );
        case SmsPayloadKind.seen:
          await txn.rawUpdate(
            'UPDATE sm_messages SET status = ? WHERE phone = ? AND outgoing = 1 '
            'AND sid = ? AND counter <= ? AND status IN (?, ?, ?)',
            [
              SecureMessageStatus.seen.name,
              phone,
              opened.refSid,
              opened.refCounter,
              SecureMessageStatus.sending.name,
              SecureMessageStatus.sent.name,
              SecureMessageStatus.delivered.name,
            ],
          );
          // The same session carried our group messages to them too.
          final seenGroups = await _groups.markSeenBy(
            txn,
            phone,
            opened.refSid!,
            opened.refCounter!,
          );
          groupChanged = seenGroups.isNotEmpty;
        case SmsPayloadKind.delete:
          await txn.delete(
            'sm_messages',
            where: 'phone = ? AND outgoing = 0 AND sid = ? AND counter = ?',
            whereArgs: [phone, opened.refSid, opened.refCounter],
          );
          groupChanged =
              await _groups.deleteIncoming(
                txn,
                phone,
                opened.refSid!,
                opened.refCounter!,
              ) !=
              null;
      }
    });
    // A group change repaints the whole list (null); a pair's, that pair.
    _changed(groupChanged ? null : phone);
    return _Outcome.done;
  }

  // ── Sending ──────────────────────────────────────────────────────────────

  /// Starts (or re-binds) a conversation with [peer].
  Future<void> startConversation(SecurePeer peer) => _serial(() async {
    await _store.upsertConversation(
      phone: peer.phone,
      name: await _hidden?.nameFor(peer.phone) ?? peer.name,
      peerKeyId: peer.keyId,
      peerPublic: peer.publicKey,
      ownKeyId: peer.own.keyId,
      ownSource: peer.own.source,
      now: _clock(),
    );
    _changed(null);
  });

  /// Queues [text] to [phone] and sends it as soon as a session allows.
  /// [ttl] (seconds) makes it a timed message (matrix row 16).
  Future<void> sendText(
    String phone,
    String text, {
    bool deleteAfterSeen = false,
    int? ttl,
  }) => _serial(() async {
    final now = _clock();
    await _store.addMessage(
      SecureMessage(
        id: _newId(),
        phone: phone,
        outgoing: true,
        body: text,
        timestamp: now,
        status: SecureMessageStatus.queued,
        deleteAfterSeen: deleteAfterSeen,
        ttl: ttl,
      ),
    );
    await _store.touchConversation(phone, now);
    _changed(phone);
    await _flush(phone);
  });

  /// A conversation without a key, with a hidden contact the key bank does
  /// not know: plain SMS, still kept out of the system's message store.
  Future<void> startPlainConversation(String phone, String name) =>
      _serial(() async {
        await _store.ensurePlainConversation(
          phone: phone,
          name: name,
          now: _clock(),
        );
        _changed(null);
      });

  /// Sends [text] unencrypted to [phone] (a keyless conversation). Never
  /// written to `content://sms`, like every SMS of the secure section.
  Future<void> sendPlain(String phone, String text) => _serial(() async {
    final now = _clock();
    final m = SecureMessage(
      id: _newId(),
      phone: phone,
      outgoing: true,
      body: text,
      timestamp: now,
      status: SecureMessageStatus.sending,
      plain: true,
    );
    await _store.addMessage(m);
    await _store.touchConversation(phone, now);
    _changed(phone);
    await _sendPlain(m);
  });

  Future<void> _sendPlain(SecureMessage m) async {
    try {
      await _send(m.phone, m.body, trackingId: m.id);
      await _store.advanceStatus(m.id, SecureMessageStatus.sent);
    } catch (e) {
      debugPrint('Sending a plain hidden SMS failed: ${e.runtimeType}');
      await _store.advanceStatus(m.id, SecureMessageStatus.failed);
    }
    _changed(m.phone);
  }

  /// A contact just hidden takes their SMS history along: [history] (from
  /// the main database) is stored here as plain messages, already read.
  Future<void> importPlainHistory(
    String phone,
    String name,
    List<({bool outgoing, String body, int timestamp})> history,
  ) => _serial(() async {
    if (history.isEmpty) return;
    var last = 0;
    for (final h in history) {
      if (await _store.hasPlain(
        phone,
        outgoing: h.outgoing,
        body: h.body,
        timestamp: h.timestamp,
      )) {
        continue;
      }
      if (last == 0) {
        await _store.ensurePlainConversation(
          phone: phone,
          name: name,
          now: h.timestamp,
        );
      }
      await _store.addMessage(
        SecureMessage(
          id: _newId(),
          phone: phone,
          outgoing: h.outgoing,
          body: h.body,
          timestamp: h.timestamp,
          status: h.outgoing
              ? SecureMessageStatus.sent
              : SecureMessageStatus.received,
          seenAt: h.outgoing ? null : h.timestamp,
          plain: true,
        ),
      );
      if (h.timestamp > last) last = h.timestamp;
    }
    if (last > 0) await _store.touchConversation(phone, last);
    _changed(null);
  });

  /// A hidden contact was renamed: so are their conversations.
  Future<void> rename(List<String> phones, String name) => _serial(() async {
    for (final phone in phones) {
      await _store.rename(phone, name);
    }
    _changed(null);
  });

  /// A failed message goes back to the queue (it is encrypted again, under
  /// the next counter: the one that failed never reached anybody).
  Future<void> retry(String id) => _serial(() async {
    final m = await _store.message(id);
    if (m == null || !m.outgoing || m.status != SecureMessageStatus.failed) {
      return;
    }
    if (m.plain) {
      await _store.db.update(
        'sm_messages',
        {'status': SecureMessageStatus.sending.name},
        where: 'id = ?',
        whereArgs: [id],
      );
      _changed(m.phone);
      await _sendPlain(m);
      return;
    }
    await _store.db.update(
      'sm_messages',
      {'status': SecureMessageStatus.queued.name, 'sid': null, 'counter': null},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed(m.phone);
    await _flush(m.phone);
  });

  /// Sends whatever is queued for [phone], or the handshake it needs first.
  Future<void> flush(String phone) => _serial(() => _flush(phone));

  /// Whether the key bank still holds both keys [c] was made with.
  Future<bool> _keysCurrent(SecureConversation c) async =>
      await _identities.ownByKeyId(c.ownKeyId!) != null &&
      await _identities.byKeyId(c.peerKeyId!, c.phone) != null;

  /// [c] on the keys the key bank holds now.
  ///
  /// A conversation used to keep the keys it was started with for ever. So
  /// after the authority gave a member a new key («گوشی گم شد» in the
  /// issuance panel) and everyone imported the new directory, every existing
  /// conversation went on encrypting to the LOST phone's key — over its old
  /// sessions, and in any new handshake too — and the member's new phone
  /// could read none of it. The same for our own key replaced. Now the
  /// conversation is re-bound to the member's current key (same directory
  /// first) and its old sessions are dropped; the next send starts a
  /// handshake with the new key. Null when the bank has no key for the
  /// number any more (the member was removed): nothing can be sent.
  Future<SecureConversation?> _current(SecureConversation c) async {
    if (!c.encrypted || await _keysCurrent(c)) return c;
    final candidates = await _identities.forNumber(c.phone);
    final next =
        candidates.where((p) => p.source == c.ownSource).firstOrNull ??
        candidates.where((p) => p.source.startsWith('directory:')).firstOrNull;
    if (next == null) {
      debugPrint('Conversation keys retired; the key bank has none for it');
      return null;
    }
    debugPrint('Conversation keys retired; moving to the current key');
    await _store.upsertConversation(
      phone: c.phone,
      name: c.name,
      peerKeyId: next.keyId,
      peerPublic: next.publicKey,
      ownKeyId: next.own.keyId,
      ownSource: next.own.source,
      now: _clock(),
      listed: false,
    );
    return _store.conversation(c.phone);
  }

  Future<void> _flush(String phone) async {
    final stored = await _store.conversation(phone);
    // A keyless conversation has nothing to encrypt or queue: plain SMS go
    // out at once (sendPlain).
    if (stored == null || !stored.encrypted) return;
    final conversation = await _current(stored);
    if (conversation == null) {
      for (final m in await _store.queued(phone)) {
        await _store.advanceStatus(m.id, SecureMessageStatus.failed);
      }
      _changed(phone);
      return;
    }
    final queued = await _store.queued(phone);
    // Group work for this member: a definition they have not had (always
    // first, so they know the group before its messages), then messages.
    final infos = await _groups.staleInfoFor(phone);
    final groupQueued = await _groups.queuedFor(phone);
    if (queued.isEmpty && infos.isEmpty && groupQueued.isEmpty) return;
    final sessions = await _store.sessions(phone);
    final session = sessions.where((s) => !s.pending).firstOrNull;
    if (session == null) {
      await _handshakeIfNeeded(conversation, sessions);
      return;
    }
    var state = session.state;
    for (final g in infos) {
      state = await _sendGroupInfo(phone, session.sid, state, g);
    }
    for (final m in queued) {
      final SmsSealed sealed;
      try {
        sealed = await _crypto.encryptText(
          session: state,
          text: m.body,
          deleteAfterSeen: m.deleteAfterSeen,
          ttlSeconds: m.ttl,
        );
      } on SmsCryptoException catch (e) {
        debugPrint('Encrypting a message failed: ${e.failure.name}');
        await _store.advanceStatus(m.id, SecureMessageStatus.failed);
        continue;
      }
      state = sealed.state;
      await _store.db.transaction((txn) async {
        await _store.updateSessionState(txn, phone, session.sid, sealed.state);
        await _store.markSending(
          txn,
          m.id,
          sid: sealed.sid!,
          counter: sealed.counter!,
          parts: sealed.parts,
        );
      });
      _changed(phone);
      try {
        await _send(phone, await _out(sealed.wire), trackingId: m.id);
        await _store.advanceStatus(m.id, SecureMessageStatus.sent);
      } catch (e) {
        debugPrint('Sending an encrypted SMS failed: ${e.runtimeType}');
        await _store.advanceStatus(m.id, SecureMessageStatus.failed);
      }
      _changed(phone);
    }
    for (final q in groupQueued) {
      state = await _sendGroupText(phone, session.sid, state, q.message);
    }
  }

  /// One member's copy of a group definition. Returns the session's next
  /// state (unchanged if encrypting failed).
  Future<Uint8List> _sendGroupInfo(
    String phone,
    int sid,
    Uint8List state,
    SecureGroup g,
  ) async {
    final SmsSealed sealed;
    try {
      sealed = await _crypto.encryptGroupInfo(
        session: state,
        info: SmsGroupInfo(
          groupId: _unhex(g.id),
          version: g.version,
          mode: SmsGroupMode.values[g.mode.index],
          name: g.name,
          members: [
            for (final m in g.members)
              SmsGroupMember(phone: m.phone, keyId: _unhex(m.keyId)),
          ],
        ),
      );
    } on SmsCryptoException catch (e) {
      debugPrint('Encrypting a group definition failed: ${e.failure.name}');
      return state;
    }
    await _store.db.transaction(
      (txn) => _store.updateSessionState(txn, phone, sid, sealed.state),
    );
    try {
      await _send(phone, await _out(sealed.wire), trackingId: 'gi-${_newId()}');
      // Only once it is out: a failed send is tried again next flush.
      await _groups.markInfoSent(g.id, phone, g.version);
    } catch (e) {
      debugPrint('Sending a group definition failed: ${e.runtimeType}');
    }
    return sealed.state;
  }

  /// One member's copy of a group message.
  Future<Uint8List> _sendGroupText(
    String phone,
    int sid,
    Uint8List state,
    SecureGroupMessage m,
  ) async {
    final SmsSealed sealed;
    try {
      sealed = await _crypto.encryptText(
        session: state,
        text: m.body,
        deleteAfterSeen: m.deleteAfterSeen,
        groupId: _unhex(m.groupId),
        ttlSeconds: m.ttl,
      );
    } on SmsCryptoException catch (e) {
      debugPrint('Encrypting a group message failed: ${e.failure.name}');
      await _groups.advanceDelivery(m.id, phone, SecureMessageStatus.failed);
      return state;
    }
    await _store.db.transaction((txn) async {
      await _store.updateSessionState(txn, phone, sid, sealed.state);
      await _groups.markDeliverySending(
        txn,
        m.id,
        phone,
        sid: sealed.sid!,
        counter: sealed.counter!,
        parts: sealed.parts,
      );
    });
    try {
      await _send(
        phone,
        await _out(sealed.wire),
        trackingId: groupTrackingId(m.id, phone),
      );
      await _groups.advanceDelivery(m.id, phone, SecureMessageStatus.sent);
    } catch (e) {
      debugPrint('Sending a group message failed: ${e.runtimeType}');
      await _groups.advanceDelivery(m.id, phone, SecureMessageStatus.failed);
    }
    _changed(null);
    return sealed.state;
  }

  /// A delivery report names a member's copy of a group message by this.
  static String groupTrackingId(String messageId, String phone) =>
      'g:$messageId:$phone';

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  Future<void> _handshakeIfNeeded(
    SecureConversation conversation,
    List<StoredSession> sessions,
  ) async {
    final phone = conversation.phone;
    final pending = sessions.where((s) => s.pending).firstOrNull;
    if (pending != null) {
      if (_clock() - pending.createdAt < pendingTimeout.inMilliseconds) return;
      await _store.deleteSession(phone, pending.sid); // unanswered: ask again
    }
    final own = await _identities.ownByKeyId(conversation.ownKeyId!);
    if (own == null) {
      debugPrint('No identity of ours for this conversation any more');
      return;
    }
    final started = await _crypto.initiate(
      secret: own.identity.secret,
      peer: conversation.peerPublic!,
      busySids: {for (final s in sessions) s.sid},
    );
    await _store.saveSession(
      StoredSession(
        phone: phone,
        sid: started.sid!,
        pending: true,
        state: started.state,
        createdAt: _clock(),
      ),
    );
    await _sendQuietly(phone, started.wire, 'hs-${_newId()}');
  }

  /// `secure_meta` key: the SIM every encrypted SMS goes out on (a
  /// subscription id); absent = the system default SMS SIM. Dual-SIM phones
  /// often have the number the key bank lists on the *other* SIM.
  static const simKey = 'sms_sim';

  Future<void> _send(
    String phone,
    String wire, {
    required String trackingId,
  }) async {
    final sim = int.tryParse(await _store.meta(simKey) ?? '');
    await _sender.send(
      phone,
      wire,
      trackingId: trackingId,
      subscriptionId: sim != null && sim >= 0 ? sim : null,
    );
  }

  Future<int?> smsSim() async => int.tryParse(await _store.meta(simKey) ?? '');

  Future<void> setSmsSim(int? subscriptionId) =>
      _store.setMeta(simKey, '${subscriptionId ?? -1}');

  /// A message or receipt as cover text when the user chose it (row 31).
  /// Handshakes are never covered: a thousand words for one SMS's worth.
  Future<String> _out(String wire) async {
    if (!_coverAllowed) return wire;
    final mode = await _store.meta(coverKey);
    if (mode != 'fa' && mode != 'en') return wire;
    try {
      return await _crypto.coverEncode(wire, persian: mode == 'fa');
    } catch (e) {
      debugPrint('Cover text failed: ${e.runtimeType}');
      return wire;
    }
  }

  Future<String?> coverMode() async =>
      _coverAllowed ? await _store.meta(coverKey) : null;

  Future<void> setCoverMode(String? mode) =>
      _store.setMeta(coverKey, mode == 'fa' || mode == 'en' ? mode! : 'off');

  /// Handshake packets and receipts: no bubble to update; a failure is
  /// logged, and the handshake is retried by [pendingTimeout].
  Future<void> _sendQuietly(
    String phone,
    String wire,
    String trackingId,
  ) async {
    try {
      await _send(phone, wire, trackingId: trackingId);
    } catch (e) {
      debugPrint('Sending a control SMS failed: ${e.runtimeType}');
    }
  }

  /// Sends a receipt on the newest session; false when there is none yet.
  Future<bool> _sendControl(
    String phone,
    String control,
    int refSid,
    int refCounter,
  ) async {
    final session = (await _store.sessions(
      phone,
    )).where((s) => !s.pending).firstOrNull;
    if (session == null) return false;
    final sealed = await _crypto.encryptControl(
      session: session.state,
      control: control,
      refSid: refSid,
      refCounter: refCounter,
    );
    await _store.db.transaction(
      (txn) => _store.updateSessionState(txn, phone, session.sid, sealed.state),
    );
    await _sendQuietly(phone, await _out(sealed.wire), 'ctl-${_newId()}');
    return true;
  }

  // ── Seen, delete ─────────────────────────────────────────────────────────

  /// The conversation is on screen: its messages are seen. Sends one
  /// «دیده شد» covering everything new (owner's decision: automatic and
  /// batched — each receipt is an SMS), unless turned off.
  Future<void> markSeen(String phone) => _serial(() async {
    await _store.markShown(phone, _clock());
    await _store.clearUnread(phone);
    _changed(null);
    if (await _store.meta(sendSeenKey) == '0') return;
    final conversation = await _store.conversation(phone);
    if (conversation == null) return;
    // The newest session anything arrived on, and the highest counter in it.
    final received = (await _store.messages(
      phone,
    )).where((m) => !m.outgoing && m.sid != null).toList();
    if (received.isEmpty) return;
    final sid = received.last.sid!;
    final upTo = received
        .where((m) => m.sid == sid)
        .map((m) => m.counter!)
        .reduce((a, b) => a > b ? a : b);
    if (conversation.seenSid == sid &&
        (conversation.seenCounter ?? -1) >= upTo) {
      return;
    }
    if (await _sendControl(phone, 'seen', sid, upTo)) {
      await _store.setSeenMark(phone, sid, upTo);
    }
  });

  /// The conversation was left: «حذف پس از دیدن» messages that were shown go.
  Future<void> leaveConversation(String phone) => _serial(() async {
    if (await _store.deleteSeenEphemeral(phone) > 0) _changed(phone);
  });

  /// «حذف برای هر دو»: our message goes on both phones.
  Future<void> deleteForBoth(String id) => _serial(() async {
    final m = await _store.message(id);
    if (m == null || !m.outgoing) return;
    if (m.sid != null && m.counter != null) {
      await _sendControl(m.phone, 'delete', m.sid!, m.counter!);
    }
    await _store.deleteMessage(id);
    _changed(m.phone);
  });

  /// «حذف» on this phone only.
  Future<void> deleteLocally(String id) => _serial(() async {
    final m = await _store.message(id);
    if (m == null) return;
    await _store.deleteMessage(id);
    _changed(m.phone);
  });

  Future<void> deleteConversation(String phone) => _serial(() async {
    await _store.deleteConversation(phone);
    _changed(null);
  });

  /// A sent/delivered/failed report from the radio for message [id].
  Future<void> onStatus(String id, String status) => _serial(() async {
    final to = switch (status) {
      'sent' => SecureMessageStatus.sent,
      'delivered' => SecureMessageStatus.delivered,
      'failed' => SecureMessageStatus.failed,
      _ => null,
    };
    if (to == null) return;
    if (id.startsWith('g:')) {
      final parts = id.split(':');
      if (parts.length != 3) return;
      if (await _groups.advanceDelivery(parts[1], parts[2], to)) {
        _changed(null);
      }
      return;
    }
    final m = await _store.message(id);
    if (m == null) return;
    if (await _store.advanceStatus(id, to)) _changed(m.phone);
  });

  // ── Groups ───────────────────────────────────────────────────────────────

  /// Makes a group of [members] (never us) and tells each of them — over a
  /// handshake first where there is no session yet. Returns its id (hex).
  Future<String> createGroup({
    required String name,
    required SecureGroupMode mode,
    required List<SecurePeer> members,
  }) => _serial(() async {
    final random = Random.secure();
    final id = keyHex([for (var i = 0; i < 8; i++) random.nextInt(256)]);
    final now = _clock();
    await _ensurePeers(members);
    await _groups.createGroup(
      id: id,
      name: name,
      mode: mode,
      members: [for (final m in members) (phone: m.phone, keyId: m.keyId)],
      now: now,
    );
    _changed(null);
    for (final m in members) {
      await _flush(m.phone);
    }
    return id;
  });

  /// The creator renames or re-populates its group. Everyone — dropped
  /// members included — is sent the new definition.
  /// [keep]: members staying whose key the bank no longer has (they are
  /// reached over the conversation that already exists).
  Future<void> editGroup(
    String id, {
    required String name,
    required List<SecurePeer> members,
    List<String> keep = const [],
  }) => _serial(() async {
    final g = await _groups.group(id);
    if (g == null || !g.isMine) return;
    await _ensurePeers(members);
    final kept = {
      for (final m in await _groups.allMembers(id))
        if (keep.contains(m.phone)) m.phone: m.keyId,
    };
    await _groups.editGroup(
      id: id,
      name: name,
      members: [
        for (final m in members) (phone: m.phone, keyId: m.keyId),
        for (final e in kept.entries)
          if (!members.any((m) => m.phone == e.key))
            (phone: e.key, keyId: e.value),
      ],
    );
    _changed(null);
    for (final m in await _groups.allMembers(id)) {
      await _flush(m.phone);
    }
  });

  /// One-to-one conversations with group members, kept out of the list
  /// until something is said in them.
  Future<void> _ensurePeers(List<SecurePeer> peers) async {
    for (final p in peers) {
      final existing = await _store.conversation(p.phone);
      if (existing != null && existing.encrypted) continue;
      await _store.upsertConversation(
        phone: p.phone,
        name: await _hidden?.nameFor(p.phone) ?? p.name,
        peerKeyId: p.keyId,
        peerPublic: p.publicKey,
        ownKeyId: p.own.keyId,
        ownSource: p.own.source,
        now: _clock(),
        listed: false,
      );
    }
  }

  /// A member we can reach: a conversation with a key, or one made from the
  /// key bank by the key id the group gives. Null when the bank has none.
  Future<bool> _reachable(String phone, String? keyId) async {
    final existing = await _store.conversation(phone);
    if (existing != null && existing.encrypted) return true;
    if (keyId == null) return false;
    final peer = await _identities.byKeyId(keyId, phone);
    if (peer == null) return false;
    await _ensurePeers([peer]);
    return true;
  }

  /// Sends [text] to the group: every member in a chat group, or — in an
  /// announcement list — every member when it is ours, else its creator.
  /// Members this phone has no key for are skipped.
  Future<void> sendGroupText(
    String groupId,
    String text, {
    bool deleteAfterSeen = false,
    int? ttl,
  }) => _serial(() async {
    final g = await _groups.group(groupId);
    if (g == null || g.left || g.pendingInfo) return;
    final keys = {for (final m in g.members) m.phone: m.keyId};
    final targets = <String>[];
    for (final phone in g.recipients) {
      if (await _reachable(phone, keys[phone])) targets.add(phone);
    }
    final now = _clock();
    final message = SecureGroupMessage(
      id: _newId(),
      groupId: groupId,
      body: text,
      timestamp: now,
      status: targets.isEmpty
          ? SecureMessageStatus.failed
          : SecureMessageStatus.sent,
      deleteAfterSeen: deleteAfterSeen,
      ttl: ttl,
    );
    await _groups.addOutgoing(message, targets);
    await _groups.touch(groupId, now);
    _changed(null);
    for (final phone in targets) {
      await _flush(phone);
    }
  });

  /// Failed copies of a group message are sent again.
  Future<void> retryGroupMessage(String id) => _serial(() async {
    for (final phone in await _groups.requeueFailed(id)) {
      await _flush(phone);
    }
    _changed(null);
  });

  /// The group is on screen: its messages are seen. One «دیده شد» per sender
  /// (to them only — owner's decision), unless receipts are off. It covers
  /// that pair's session up to the newest group message, one-to-one messages
  /// before it included: a receipt names a point in a session, not a thread.
  Future<void> markGroupSeen(String groupId) => _serial(() async {
    await _groups.markShown(groupId, _clock());
    await _groups.clearUnread(groupId);
    _changed(null);
    if (await _store.meta(sendSeenKey) == '0') return;
    for (final mark in await _groups.seenMarks(groupId)) {
      final c = await _store.conversation(mark.sender);
      if (c == null) continue;
      if (c.seenSid == mark.sid && (c.seenCounter ?? -1) >= mark.upTo) {
        continue;
      }
      if (await _sendControl(mark.sender, 'seen', mark.sid, mark.upTo)) {
        await _store.setSeenMark(mark.sender, mark.sid, mark.upTo);
      }
    }
  });

  /// The group was left: «حذف پس از دیدن» messages that were shown go.
  Future<void> leaveGroupThread(String groupId) => _serial(() async {
    if (await _groups.deleteSeenEphemeral(groupId) > 0) _changed(null);
  });

  /// «حذف برای هر دو» on a group message of ours: every member's copy.
  Future<void> deleteGroupMessageForAll(String id) => _serial(() async {
    final m = await _groups.message(id);
    if (m == null || !m.outgoing) return;
    for (final d in m.deliveries) {
      if (d.sid != null && d.counter != null) {
        await _sendControl(d.phone, 'delete', d.sid!, d.counter!);
      }
    }
    await _groups.deleteMessage(id);
    _changed(null);
  });

  Future<void> deleteGroupMessageLocally(String id) => _serial(() async {
    await _groups.deleteMessage(id);
    _changed(null);
  });

  /// On this phone only; members keep theirs.
  Future<void> deleteGroup(String id) => _serial(() async {
    await _groups.deleteGroup(id);
    _changed(null);
  });

  // ── Timed messages (row 16) ──────────────────────────────────────────────

  /// Deletes every timed message whose time is up; how many went.
  Future<int> purgeExpired() => _serial(() async {
    final n = await _store.purgeExpired(_clock());
    if (n > 0) _changed(null);
    return n;
  });

  /// When the next timed message goes, if one is running.
  Future<int?> nextExpiry() => _serial(_store.nextExpiry);

  Future<bool> sendsSeenReceipts() async =>
      await _store.meta(sendSeenKey) != '0';

  Future<void> setSendsSeenReceipts(bool on) =>
      _store.setMeta(sendSeenKey, on ? '1' : '0');
}
