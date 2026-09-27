import 'package:flutter/services.dart';

/// Why an SMS crypto operation failed. Mirrors `SmsCryptoException.Code` in
/// `android/.../smscrypto/SmsCryptoException.kt` (plus the handler's own
/// `BAD_ARGS` / `FAILED`).
enum SmsCryptoFailure {
  /// Not one of our packets (or not one this build can read).
  notOurs,

  /// A packet of another kind than the operation expects.
  wrongType,

  /// A key, identity or state blob that does not parse or validate.
  badKey,

  /// The packet names a sender other than the peer given.
  wrongPeer,

  /// The packet was made for another identity.
  notForUs,

  /// A message or response of another session.
  wrongSession,

  /// A message already received — the carrier delivered it twice.
  duplicate,

  /// A counter too far ahead to be a delayed message.
  tooFarAhead,

  /// Tampered, truncated or under another key. The state is unchanged.
  authFailed,

  /// Decrypted, but sealed by a newer build (unknown payload kind).
  badPayload,

  /// The session's send counter is exhausted; start a new one.
  rekeyRequired,

  /// Anything else — a bad argument, a platform error.
  failed,
}

class SmsCryptoException implements Exception {
  const SmsCryptoException(this.failure);
  final SmsCryptoFailure failure;

  static SmsCryptoFailure _fromCode(String code) => switch (code) {
    'NOT_OURS' => SmsCryptoFailure.notOurs,
    'WRONG_TYPE' => SmsCryptoFailure.wrongType,
    'BAD_KEY' => SmsCryptoFailure.badKey,
    'WRONG_PEER' => SmsCryptoFailure.wrongPeer,
    'NOT_FOR_US' => SmsCryptoFailure.notForUs,
    'WRONG_SESSION' => SmsCryptoFailure.wrongSession,
    'DUPLICATE' => SmsCryptoFailure.duplicate,
    'TOO_FAR_AHEAD' => SmsCryptoFailure.tooFarAhead,
    'AUTH_FAILED' => SmsCryptoFailure.authFailed,
    'BAD_PAYLOAD' => SmsCryptoFailure.badPayload,
    'REKEY_REQUIRED' => SmsCryptoFailure.rekeyRequired,
    _ => SmsCryptoFailure.failed,
  };

  @override
  String toString() => 'SmsCryptoException($failure)';
}

/// A member's key pair. [secret] is private and belongs only in the secure
/// section; [publicKey] (ML-KEM-768 + X25519, 1217 bytes) is what others
/// store; [keyId] (8 bytes) is how packets name it.
class SmsIdentity {
  const SmsIdentity({
    required this.secret,
    required this.publicKey,
    required this.keyId,
  });
  final Uint8List secret;
  final Uint8List publicKey;
  final Uint8List keyId;
}

enum SmsPacketType { message, init, response }

/// What [SmsCryptoService.inspect] reads off a packet without any key: enough
/// to route it to a peer and a session.
class SmsPacketInfo {
  const SmsPacketInfo({
    required this.type,
    required this.sid,
    this.counter,
    this.senderKid,
    this.recipientKid,
  });
  final SmsPacketType type;
  final int sid;

  /// Messages only.
  final int? counter;

  /// Handshake packets only.
  final Uint8List? senderKid;
  final Uint8List? recipientKid;
}

/// An outgoing packet and the state to store in place of the old one.
class SmsSealed {
  const SmsSealed({
    required this.state,
    required this.wire,
    required this.parts,
    this.sid,
  });

  /// The pending handshake (after `initiate`) or the session (otherwise).
  final Uint8List state;

  /// The SMS text to send.
  final String wire;

  /// How many SMS parts [wire] costs.
  final int parts;
  final int? sid;
}

class SmsOpened {
  const SmsOpened({required this.session, required this.text});
  final Uint8List session;
  final String text;
}

/// The SMS crypto (ML-KEM-768 + X25519 handshake, per-message AES-256-GCM
/// keys), over `…/sms_crypto`. See `docs/architecture/editions.md`.
///
/// **Stateless**: keys, pending handshakes and sessions go in as bytes and
/// the next state comes back. The caller stores what it gets back in the
/// secure section and never in the main database — and must store it
/// *before* sending the wire, so a crash can never reuse a message key.
class SmsCryptoService {
  const SmsCryptoService();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/sms_crypto',
  );

  /// Mirrors `Wire.PREFIX` in `android/.../smscrypto/Wire.kt`.
  static const String wirePrefix = '#E:';

  /// A cheap test for the receive path: could [text] be one of ours?
  static bool looksEncrypted(String text) => text.startsWith(wirePrefix);

  Future<SmsIdentity> generateIdentity() async =>
      _identity(await _call<Map>('generateIdentity', const {}));

  /// The deterministic identity of a 32-byte [seed].
  Future<SmsIdentity> identityFromSeed(Uint8List seed) async =>
      _identity(await _call<Map>('identityFromSeed', {'seed': seed}));

  /// The public half of a stored [secret].
  Future<({Uint8List publicKey, Uint8List keyId})> publicIdentity(
    Uint8List secret,
  ) async {
    final m = await _call<Map>('publicIdentity', {'secret': secret});
    return (
      publicKey: m['public'] as Uint8List,
      keyId: m['keyId'] as Uint8List,
    );
  }

  /// Validates somebody's public identity; returns its key id.
  /// [SmsCryptoFailure.badKey] for a key that must not be stored.
  Future<Uint8List> checkPublic(Uint8List publicKey) async =>
      (await _call<Map>('checkPublic', {'public': publicKey}))['keyId']
          as Uint8List;

  /// Null for anything that is not a well-formed packet of ours.
  Future<SmsPacketInfo?> inspect(String text) async {
    if (!looksEncrypted(text)) return null;
    final Map? m;
    try {
      m = await _channel.invokeMethod<Map>('inspect', {'text': text});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    if (m == null) return null;
    return SmsPacketInfo(
      type: SmsPacketType.values.byName(m['type'] as String),
      sid: m['sid'] as int,
      counter: m['counter'] as int?,
      senderKid: m['senderKid'] as Uint8List?,
      recipientKid: m['recipientKid'] as Uint8List?,
    );
  }

  /// Starts a session with [peer]; [SmsSealed.state] is the pending handshake.
  Future<SmsSealed> initiate({
    required Uint8List secret,
    required Uint8List peer,
    Set<int> busySids = const {},
  }) async => _sealed(
    await _call<Map>('initiate', {
      'secret': secret,
      'peer': peer,
      'busySids': busySids.toList(),
    }),
    'pending',
  );

  /// Answers a session request; [SmsSealed.state] is the new session.
  Future<SmsSealed> respond({
    required Uint8List secret,
    required Uint8List peer,
    required String text,
  }) async => _sealed(
    await _call<Map>('respond', {'secret': secret, 'peer': peer, 'text': text}),
    'session',
  );

  /// Finishes the initiator's side; returns the session.
  Future<Uint8List> complete({
    required Uint8List secret,
    required Uint8List peer,
    required Uint8List pending,
    required String text,
  }) async =>
      (await _call<Map>('complete', {
            'secret': secret,
            'peer': peer,
            'pending': pending,
            'text': text,
          }))['session']
          as Uint8List;

  /// Both sides sent a request: true when ours is the one that goes ahead.
  Future<bool> ownInitWins(Uint8List ownKid, Uint8List peerKid) =>
      _call<bool>('ownInitWins', {'ownKid': ownKid, 'peerKid': peerKid});

  Future<SmsSealed> encryptText({
    required Uint8List session,
    required String text,
  }) async => _sealed(
    await _call<Map>('encryptText', {'session': session, 'text': text}),
    'session',
  );

  Future<SmsOpened> decrypt({
    required Uint8List session,
    required String text,
  }) async {
    final m = await _call<Map>('decrypt', {'session': session, 'text': text});
    return SmsOpened(
      session: m['session'] as Uint8List,
      text: m['text'] as String,
    );
  }

  SmsIdentity _identity(Map m) => SmsIdentity(
    secret: m['secret'] as Uint8List,
    publicKey: m['public'] as Uint8List,
    keyId: m['keyId'] as Uint8List,
  );

  SmsSealed _sealed(Map m, String stateKey) => SmsSealed(
    state: m[stateKey] as Uint8List,
    wire: m['wire'] as String,
    parts: m['parts'] as int,
    sid: m['sid'] as int?,
  );

  Future<T> _call<T>(String method, Map<String, Object?> args) async {
    try {
      final value = await _channel.invokeMethod<T>(method, args);
      if (value == null) {
        throw const SmsCryptoException(SmsCryptoFailure.failed);
      }
      return value;
    } on PlatformException catch (e) {
      throw SmsCryptoException(SmsCryptoException._fromCode(e.code));
    } on MissingPluginException {
      throw const SmsCryptoException(SmsCryptoFailure.failed);
    }
  }
}
