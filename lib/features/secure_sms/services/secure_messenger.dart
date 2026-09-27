import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

import '../repositories/secure_queue_repository.dart';
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
    SecureQueueRepository? queue,
    SecureIdentities? identities,
    SmsCryptoService crypto = const SmsCryptoService(),
    SecureSmsSender? sender,
    int Function()? clock,
    String Function()? newId,
  }) : _store = store ?? SecureMessageStore(),
       _queue = queue ?? SecureQueueRepository(),
       _identities = identities ?? SecureIdentities(),
       _crypto = crypto,
       _sender = sender ?? NativeSecureSmsSender(),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _newId = newId ?? (() => const Uuid().v4());

  final SecureMessageStore _store;
  final SecureQueueRepository _queue;
  final SecureIdentities _identities;
  final SmsCryptoService _crypto;
  final SecureSmsSender _sender;
  final int Function() _clock;
  final String Function() _newId;

  /// A packet that could not be used for this long, or this many tries, is
  /// dropped: its handshake is not coming.
  static const maxWait = Duration(days: 7);
  static const maxAttempts = 50;

  /// Our session request is re-sent when unanswered this long.
  static const pendingTimeout = Duration(hours: 24);

  /// `secure_meta` key: whether «دیده شد» receipts are sent (default on).
  static const sendSeenKey = 'send_seen_receipts';

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
    final phone =
        await _crypto.canonicalPhone(packet.address) ?? packet.address;
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

  Future<_Outcome> _onInit(
    String phone,
    InboxPacket packet,
    SmsPacketInfo info,
  ) async {
    final own = await _identities.ownByKeyId(keyHex(info.recipientKid!));
    if (own == null) return _Outcome.done; // for a key this phone does not hold
    final peer = await _identities.byKeyId(keyHex(info.senderKid!), phone);
    if (peer == null) {
      return _Outcome.done; // a sender the key bank does not know
    }

    final sessions = await _store.sessions(phone);
    // The same request delivered twice: answered already.
    if (sessions.any((s) => s.sid == info.sid && !s.pending)) {
      return _Outcome.done;
    }
    // Both sides asked at once. Each phone decides the same way from the two
    // key ids; the loser drops its own request and answers the other one.
    for (final mine in sessions.where((s) => s.pending)) {
      if (await _crypto.ownInitWins(own.identity.keyId, info.senderKid!)) {
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
      name: peer.name,
      peerKeyId: peer.keyId,
      peerPublic: peer.publicKey,
      ownKeyId: own.keyId,
      ownSource: own.source,
      now: now,
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
    if (conversation == null) return _Outcome.done;
    final own = await _identities.ownByKeyId(conversation.ownKeyId);
    if (own == null) return _Outcome.done;
    final Uint8List session;
    try {
      session = await _crypto.complete(
        secret: own.identity.secret,
        peer: conversation.peerPublic,
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
    await _store.db.transaction((txn) async {
      await _store.updateSessionState(txn, phone, session.sid, opened.session);
      switch (opened.kind) {
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
        case SmsPayloadKind.delete:
          await txn.delete(
            'sm_messages',
            where: 'phone = ? AND outgoing = 0 AND sid = ? AND counter = ?',
            whereArgs: [phone, opened.refSid, opened.refCounter],
          );
      }
    });
    _changed(phone);
    return _Outcome.done;
  }

  // ── Sending ──────────────────────────────────────────────────────────────

  /// Starts (or re-binds) a conversation with [peer].
  Future<void> startConversation(SecurePeer peer) => _serial(() async {
    await _store.upsertConversation(
      phone: peer.phone,
      name: peer.name,
      peerKeyId: peer.keyId,
      peerPublic: peer.publicKey,
      ownKeyId: peer.own.keyId,
      ownSource: peer.own.source,
      now: _clock(),
    );
    _changed(null);
  });

  /// Queues [text] to [phone] and sends it as soon as a session allows.
  Future<void> sendText(
    String phone,
    String text, {
    bool deleteAfterSeen = false,
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
      ),
    );
    await _store.touchConversation(phone, now);
    _changed(phone);
    await _flush(phone);
  });

  /// A failed message goes back to the queue (it is encrypted again, under
  /// the next counter: the one that failed never reached anybody).
  Future<void> retry(String id) => _serial(() async {
    final m = await _store.message(id);
    if (m == null || !m.outgoing || m.status != SecureMessageStatus.failed) {
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

  Future<void> _flush(String phone) async {
    final conversation = await _store.conversation(phone);
    if (conversation == null) return;
    final queued = await _store.queued(phone);
    if (queued.isEmpty) return;
    final sessions = await _store.sessions(phone);
    final session = sessions.where((s) => !s.pending).firstOrNull;
    if (session == null) {
      await _handshakeIfNeeded(conversation, sessions);
      return;
    }
    var state = session.state;
    for (final m in queued) {
      final SmsSealed sealed;
      try {
        sealed = await _crypto.encryptText(
          session: state,
          text: m.body,
          deleteAfterSeen: m.deleteAfterSeen,
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
        await _sender.send(phone, sealed.wire, trackingId: m.id);
        await _store.advanceStatus(m.id, SecureMessageStatus.sent);
      } catch (e) {
        debugPrint('Sending an encrypted SMS failed: ${e.runtimeType}');
        await _store.advanceStatus(m.id, SecureMessageStatus.failed);
      }
      _changed(phone);
    }
  }

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
    final own = await _identities.ownByKeyId(conversation.ownKeyId);
    if (own == null) {
      debugPrint('No identity of ours for this conversation any more');
      return;
    }
    final started = await _crypto.initiate(
      secret: own.identity.secret,
      peer: conversation.peerPublic,
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

  /// Handshake packets and receipts: no bubble to update; a failure is
  /// logged, and the handshake is retried by [pendingTimeout].
  Future<void> _sendQuietly(
    String phone,
    String wire,
    String trackingId,
  ) async {
    try {
      await _sender.send(phone, wire, trackingId: trackingId);
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
    await _sendQuietly(phone, sealed.wire, 'ctl-${_newId()}');
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
    final m = await _store.message(id);
    if (m == null) return;
    if (await _store.advanceStatus(id, to)) _changed(m.phone);
  });

  Future<bool> sendsSeenReceipts() async =>
      await _store.meta(sendSeenKey) != '0';

  Future<void> setSendsSeenReceipts(bool on) =>
      _store.setMeta(sendSeenKey, on ? '1' : '0');
}
