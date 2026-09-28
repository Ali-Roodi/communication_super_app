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

  // ── Key bank ──

  /// Not a key file (wrong kind of file, or damaged beyond reading).
  notAKeyFile,

  /// The password does not open the key file.
  wrongPassword,

  /// Signed by an authority this build does not trust.
  untrusted,

  /// The authority's signature does not verify: the file was altered.
  badSignature,

  /// Signed, but its contents contradict themselves.
  badBundle,

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
    'NOT_A_KEY_FILE' => SmsCryptoFailure.notAKeyFile,
    'WRONG_PASSWORD' => SmsCryptoFailure.wrongPassword,
    'UNTRUSTED' => SmsCryptoFailure.untrusted,
    'BAD_SIGNATURE' => SmsCryptoFailure.badSignature,
    'BAD_BUNDLE' => SmsCryptoFailure.badBundle,
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
    this.control = false,
    this.senderKid,
    this.recipientKid,
  });
  final SmsPacketType type;
  final int sid;

  /// Messages only.
  final int? counter;

  /// A receipt (seen / delete), not a message to read.
  final bool control;

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
    this.counter,
  });

  /// The pending handshake (after `initiate`) or the session (otherwise).
  final Uint8List state;

  /// The SMS text to send.
  final String wire;

  /// How many SMS parts [wire] costs.
  final int parts;
  final int? sid;

  /// For a message: the counter it travelled with (with [sid], its name).
  final int? counter;
}

/// One member of a [KeyDirectory].
class DirectoryMember {
  const DirectoryMember({
    required this.name,
    required this.phones,
    required this.publicKey,
    required this.keyId,
  });
  final String name;

  /// Canonical (see `canonicalPhone`).
  final List<String> phones;
  final Uint8List publicKey;
  final Uint8List keyId;
}

/// «دفترچهٔ کلید»: an organization's members, as its authority signed them.
class KeyDirectory {
  const KeyDirectory({
    required this.authorityId,
    required this.directoryId,
    required this.serial,
    required this.name,
    required this.members,
  });
  final Uint8List authorityId;

  /// Fixed for an organization; a newer copy replaces an older one.
  final Uint8List directoryId;

  /// Grows with every issue (the issue time, ms since epoch).
  final int serial;
  final String name;
  final List<DirectoryMember> members;
}

/// A verified key file: the signed directory (kept as received, so it can
/// be verified again) and, usually, the importing member's own key.
class OpenedKeyFile {
  const OpenedKeyFile({
    required this.signed,
    required this.directory,
    this.memberIndex,
    this.member,
  });
  final Uint8List signed;
  final KeyDirectory directory;
  final int? memberIndex;
  final SmsIdentity? member;
}

enum SmsPayloadKind { text, seen, delete }

/// A decrypted message: the next session state, the message's own name
/// ([sid], [counter]) and what it carried.
class SmsDecrypted {
  const SmsDecrypted({
    required this.session,
    required this.sid,
    required this.counter,
    required this.kind,
    this.text,
    this.deleteAfterSeen = false,
    this.refSid,
    this.refCounter,
  });
  final Uint8List session;
  final int sid;
  final int counter;
  final SmsPayloadKind kind;

  /// [SmsPayloadKind.text] only.
  final String? text;
  final bool deleteAfterSeen;

  /// [SmsPayloadKind.seen] / [SmsPayloadKind.delete]: the message referred to.
  final int? refSid;
  final int? refCounter;
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
      control: m['control'] == true,
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
    bool deleteAfterSeen = false,
  }) async => _sealed(
    await _call<Map>('encryptText', {
      'session': session,
      'text': text,
      'deleteAfterSeen': deleteAfterSeen,
    }),
    'session',
  );

  /// A receipt: [control] is `seen` (everything up to [refCounter] of
  /// [refSid]) or `delete` (message [refCounter] of [refSid]).
  Future<SmsSealed> encryptControl({
    required Uint8List session,
    required String control,
    required int refSid,
    required int refCounter,
  }) async => _sealed(
    await _call<Map>('encryptControl', {
      'session': session,
      'control': control,
      'refSid': refSid,
      'refCounter': refCounter,
    }),
    'session',
  );

  Future<SmsDecrypted> decrypt({
    required Uint8List session,
    required String text,
  }) async {
    final m = await _call<Map>('decrypt', {'session': session, 'text': text});
    return SmsDecrypted(
      session: m['session'] as Uint8List,
      sid: m['sid'] as int,
      counter: m['counter'] as int,
      kind: SmsPayloadKind.values.byName(m['kind'] as String),
      text: m['text'] as String?,
      deleteAfterSeen: m['deleteAfterSeen'] == true,
      refSid: m['refSid'] as int?,
      refCounter: m['refCounter'] as int?,
    );
  }

  /// Opens records Kotlin sealed to [secret]'s public key (`SealedBox`):
  /// one result per blob, null for a blob that does not open with it.
  Future<List<Uint8List?>> openSealed({
    required Uint8List secret,
    required List<Uint8List> blobs,
  }) async {
    if (blobs.isEmpty) return const [];
    final opened = await _call<List>('openSealed', {
      'secret': secret,
      'blobs': blobs,
    });
    return opened.cast<Uint8List?>();
  }

  // ── Key bank ──────────────────────────────────────────────────────────────

  /// The spelling keys are derived from (`Canon.phone`): `09…` for Iranian
  /// numbers. Null for anything that is not a phone number.
  Future<String?> canonicalPhone(String phone) async {
    try {
      return await _channel.invokeMethod<String>('canonicalPhone', {
        'phone': phone,
      });
    } on PlatformException {
      return null;
    }
  }

  /// A passphrase group. Runs Argon2id with 64 MiB — about a second; the
  /// result ([group]) is the group's secret and belongs in the secure section.
  Future<({Uint8List group, Uint8List groupId})> deriveGroup({
    required String name,
    required String passphrase,
  }) async {
    final m = await _call<Map>('deriveGroup', {
      'name': name,
      'passphrase': passphrase,
    });
    return (group: m['group'] as Uint8List, groupId: m['groupId'] as Uint8List);
  }

  /// The identity of the group member who owns [phone].
  Future<SmsIdentity> groupMember({
    required Uint8List group,
    required String phone,
  }) async => _identity(
    await _call<Map>('groupMember', {'group': group, 'phone': phone}),
  );

  /// Opens and verifies a key file against [anchors] (trusted authority
  /// public keys).
  Future<OpenedKeyFile> openKeyFile({
    required Uint8List file,
    required String password,
    required List<Uint8List> anchors,
  }) async {
    final m = await _call<Map>('openKeyFile', {
      'file': file,
      'password': password,
      'anchors': anchors,
    });
    final member = m['member'] as Map?;
    return OpenedKeyFile(
      signed: m['signed'] as Uint8List,
      directory: _directory(m['directory'] as Map),
      memberIndex: member?['index'] as int?,
      member: member == null ? null : _identity(member),
    );
  }

  /// Verifies a stored signed directory again.
  Future<KeyDirectory> verifyDirectory({
    required Uint8List signed,
    required List<Uint8List> anchors,
  }) async => _directory(
    await _call<Map>('verifyDirectory', {'signed': signed, 'anchors': anchors}),
  );

  /// The 8-byte id of an authority public key.
  Future<Uint8List> authorityId(Uint8List publicKey) =>
      _call<Uint8List>('authorityId', {'public': publicKey});

  KeyDirectory _directory(Map m) => KeyDirectory(
    authorityId: m['authorityId'] as Uint8List,
    directoryId: m['directoryId'] as Uint8List,
    serial: m['serial'] as int,
    name: m['name'] as String,
    members: [
      for (final e in (m['members'] as List).cast<Map>())
        DirectoryMember(
          name: e['name'] as String,
          phones: (e['phones'] as List).cast<String>(),
          publicKey: e['public'] as Uint8List,
          keyId: e['keyId'] as Uint8List,
        ),
    ],
  );

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
    counter: m['counter'] as int?,
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
