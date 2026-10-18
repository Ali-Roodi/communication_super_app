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

  /// A session request from our own key.
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

/// A key pair (ML-KEM-768 + X25519). [secret] is private and belongs only in
/// the secure section. For a member's own key (from a key file),
/// [publicKey] is its X25519 key and [keyId] its certificate's key id; for
/// the secure section's sealing key, [publicKey] is the full public key.
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
    this.certPhone,
    this.certGeneration,
  });
  final SmsPacketType type;
  final int sid;

  /// Messages only.
  final int? counter;

  /// A receipt (seen / delete), not a message to read.
  final bool control;

  /// Handshake packets only: what the certificate it carries says —
  /// **not yet verified**, `certRespond` / `certComplete` do that. There is
  /// no recipient: a request is for whoever holds the number it went to.
  final Uint8List? senderKid;
  final String? certPhone;
  final int? certGeneration;
}

/// «گواهی عضو» (`MemberCert`): the authority's statement that a key belongs
/// to the member at [phone]. [cert] is the 103 bytes as they travel.
class MemberCertInfo {
  const MemberCertInfo({
    required this.cert,
    required this.keyId,
    required this.phone,
    required this.generation,
  });
  final Uint8List cert;
  final Uint8List keyId;

  /// Canonical, always a mobile (`09…`).
  final String phone;

  /// Raised by the issuance panel's «گوشی گم شد»; a phone that has seen a
  /// member's generation refuses an older one.
  final int generation;
}

/// The result of a certificate handshake step: the state to store, the
/// SMS to send (none for `certComplete`), and who is on the other side.
class SmsCertHandshake {
  const SmsCertHandshake({
    required this.session,
    required this.sid,
    required this.peer,
    this.wire,
    this.parts,
  });
  final Uint8List session;
  final int sid;
  final MemberCertInfo peer;
  final String? wire;
  final int? parts;
}

/// `Upgrade`'s answer: [answer] is sealed on the old session (and carries
/// its next state); [upgraded] is the new, post-quantum session [upgradedSid].
class SmsUpgradeAccepted {
  const SmsUpgradeAccepted({
    required this.answer,
    required this.upgraded,
    required this.upgradedSid,
  });
  final SmsSealed answer;
  final Uint8List upgraded;
  final int upgradedSid;
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

  /// The pending handshake (after `certInitiate`) or the session (otherwise).
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

  /// The member's X25519 key; [keyId] is the key id their certificate
  /// carries (`MemberCert.keyIdOf`).
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

/// A verified key file: the signed directory (kept as received) and the
/// importing member's own key and certificate. An update file
/// (`openUpdateFile`) has the directory only.
class OpenedKeyFile {
  const OpenedKeyFile({
    required this.signed,
    required this.directory,
    this.own,
  });
  final Uint8List signed;
  final KeyDirectory directory;

  /// The importing member's key; null for an update file.
  final OwnKey? own;
}

/// The member key a key file carries, with the certificate that names it.
class OwnKey {
  const OwnKey({
    required this.index,
    required this.identity,
    required this.cert,
  });

  /// The member's place in the directory.
  final int index;

  /// [SmsIdentity.publicKey] is the member's X25519 key and
  /// [SmsIdentity.keyId] the certificate's key id.
  final SmsIdentity identity;

  /// Verified against the directory and the authority.
  final MemberCertInfo cert;
}

/// [pqOffer] / [pqAccept] are the two halves of the background post-quantum
/// upgrade (`Upgrade`) — control packets, never shown.
enum SmsPayloadKind {
  text,
  seen,
  delete,
  groupInfo,
  pqOffer,
  pqAccept,

  /// The offerer has the upgraded session (sent on it).
  pqDone,
}

/// How members answer in a group (`Payload.GROUP_MODE_*`).
enum SmsGroupMode {
  /// A reply goes to every member.
  chat,

  /// A reply goes to the creator only (an announcement list).
  announce,
}

class SmsGroupMember {
  const SmsGroupMember({required this.phone, required this.keyId});

  /// Canonical digits.
  final String phone;
  final Uint8List keyId;
}

/// A group as its creator defines it (`Payload.GroupInfo`). [version] grows
/// with every change; a receiver keeps only the newest.
class SmsGroupInfo {
  const SmsGroupInfo({
    required this.groupId,
    required this.version,
    required this.mode,
    required this.name,
    required this.members,
  });
  final Uint8List groupId;
  final int version;
  final SmsGroupMode mode;
  final String name;
  final List<SmsGroupMember> members;
}

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
    this.groupId,
    this.groupInfo,
    this.ttlSeconds,
    this.pqKey,
    this.pqSid,
    this.pqCiphertext,
  });

  /// [SmsPayloadKind.pqOffer]: the offerer's ML-KEM key.
  final Uint8List? pqKey;

  /// [SmsPayloadKind.pqAccept]: the upgraded session and the ciphertext.
  final int? pqSid;
  final Uint8List? pqCiphertext;
  final Uint8List session;
  final int sid;
  final int counter;
  final SmsPayloadKind kind;

  /// A text that belongs to a group (8 bytes).
  final Uint8List? groupId;

  /// [SmsPayloadKind.groupInfo] only.
  final SmsGroupInfo? groupInfo;

  /// [SmsPayloadKind.text] only.
  final String? text;
  final bool deleteAfterSeen;

  /// A timed text (matrix row 16): how long it lives once shown.
  final int? ttlSeconds;

  /// [SmsPayloadKind.seen] / [SmsPayloadKind.delete]: the message referred to.
  final int? refSid;
  final int? refCounter;
}

/// The SMS crypto (the certificate handshake, its background ML-KEM-768
/// upgrade, per-message AES-256-GCM keys), over `…/sms_crypto`. See `docs/architecture/editions.md`.
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
      certPhone: m['certPhone'] as String?,
      certGeneration: m['certGeneration'] as int?,
    );
  }

  // ── The certificate handshake (`CertHandshake`) ───────────────────────────

  /// Starts a session with whoever holds the number it goes to, carrying our
  /// [cert]; [SmsSealed.state] is the pending handshake.
  Future<SmsSealed> certInitiate({
    required Uint8List cert,
    Set<int> busySids = const {},
  }) async => _sealed(
    await _call<Map>('certInitiate', {
      'cert': cert,
      'busySids': busySids.toList(),
    }),
    'pending',
  );

  /// Answers a certificate request after checking its certificate against
  /// [anchors]. [SmsCryptoFailure.untrusted] for one the authority did not
  /// sign.
  Future<SmsCertHandshake> certRespond({
    required Uint8List secret,
    required Uint8List cert,
    required String text,
    required List<Uint8List> anchors,
  }) async {
    final m = await _call<Map>('certRespond', {
      'secret': secret,
      'cert': cert,
      'text': text,
      'anchors': anchors,
    });
    return SmsCertHandshake(
      session: m['session'] as Uint8List,
      sid: m['sid'] as int,
      peer: _cert(m['peer'] as Map),
      wire: m['wire'] as String,
      parts: m['parts'] as int,
    );
  }

  /// Finishes our side of a certificate handshake.
  Future<SmsCertHandshake> certComplete({
    required Uint8List secret,
    required Uint8List cert,
    required Uint8List pending,
    required String text,
    required List<Uint8List> anchors,
  }) async {
    final m = await _call<Map>('certComplete', {
      'secret': secret,
      'cert': cert,
      'pending': pending,
      'text': text,
      'anchors': anchors,
    });
    return SmsCertHandshake(
      session: m['session'] as Uint8List,
      sid: m['sid'] as int,
      peer: _cert(m['peer'] as Map),
    );
  }

  /// What a stored certificate says (structure only).
  Future<MemberCertInfo> certInfo(Uint8List cert) async =>
      _cert(await _call<Map>('certInfo', {'cert': cert}));

  // ── The background post-quantum upgrade (`Upgrade`) ───────────────────────

  /// Our ML-KEM key, sealed on [session] (a control packet, ~11 parts).
  Future<SmsSealed> upgradeOffer({
    required Uint8List session,
    required Uint8List secret,
  }) async => _sealed(
    await _call<Map>('upgradeOffer', {'session': session, 'secret': secret}),
    'session',
  );

  /// Answers an offer whose [key] arrived on [session] (the state after it).
  Future<SmsUpgradeAccepted> upgradeAccept({
    required Uint8List session,
    required Uint8List key,
    Set<int> busySids = const {},
  }) async {
    final m = await _call<Map>('upgradeAccept', {
      'session': session,
      'key': key,
      'busySids': busySids.toList(),
    });
    return SmsUpgradeAccepted(
      answer: _sealed(m['answer'] as Map, 'session'),
      upgraded: m['upgraded'] as Uint8List,
      upgradedSid: m['upgradedSid'] as int,
    );
  }

  /// The offerer's upgraded session from the answer.
  Future<Uint8List> upgradeComplete({
    required Uint8List session,
    required Uint8List secret,
    required int sid,
    required Uint8List ciphertext,
  }) async =>
      (await _call<Map>('upgradeComplete', {
            'session': session,
            'secret': secret,
            'sid': sid,
            'ciphertext': ciphertext,
          }))['session']
          as Uint8List;

  MemberCertInfo _cert(Map m) => MemberCertInfo(
    cert: m['cert'] as Uint8List,
    keyId: m['keyId'] as Uint8List,
    phone: m['phone'] as String,
    generation: m['generation'] as int,
  );

  /// Both sides sent a request: true when ours is the one that goes ahead.
  Future<bool> ownInitWins(Uint8List ownKid, Uint8List peerKid) =>
      _call<bool>('ownInitWins', {'ownKid': ownKid, 'peerKid': peerKid});

  /// [groupId] (8 bytes) makes it a group message; [ttlSeconds] a timed one.
  Future<SmsSealed> encryptText({
    required Uint8List session,
    required String text,
    bool deleteAfterSeen = false,
    Uint8List? groupId,
    int? ttlSeconds,
  }) async => _sealed(
    await _call<Map>('encryptText', {
      'session': session,
      'text': text,
      'deleteAfterSeen': deleteAfterSeen,
      'groupId': ?groupId,
      'ttlSeconds': ?ttlSeconds,
    }),
    'session',
  );

  /// A group's definition, as a control packet (no notification).
  Future<SmsSealed> encryptGroupInfo({
    required Uint8List session,
    required SmsGroupInfo info,
  }) async => _sealed(
    await _call<Map>('encryptGroupInfo', {
      'session': session,
      'info': {
        'groupId': info.groupId,
        'version': info.version,
        'mode': info.mode.index,
        'name': info.name,
        'members': [
          for (final m in info.members) {'phone': m.phone, 'keyId': m.keyId},
        ],
      },
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

  /// «متن پوششی» (row 31): [wire] as ordinary-looking words, which every
  /// receiver turns back into [wire] before reading it.
  Future<String> coverEncode(String wire, {required bool persian}) =>
      _call<String>('coverEncode', {'wire': wire, 'persian': persian});

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
      groupId: m['groupId'] as Uint8List?,
      groupInfo: m['kind'] == 'groupInfo' ? _groupInfo(m) : null,
      ttlSeconds: (m['ttlSeconds'] as num?)?.toInt(),
      pqKey: m['pqKey'] as Uint8List?,
      pqSid: m['pqSid'] as int?,
      pqCiphertext: m['pqCiphertext'] as Uint8List?,
    );
  }

  SmsGroupInfo _groupInfo(Map m) => SmsGroupInfo(
    groupId: m['groupId'] as Uint8List,
    version: m['version'] as int,
    mode: SmsGroupMode.values[m['mode'] as int],
    name: m['name'] as String,
    members: [
      for (final e in (m['members'] as List).cast<Map>())
        SmsGroupMember(
          phone: e['phone'] as String,
          keyId: e['keyId'] as Uint8List,
        ),
    ],
  );

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
    final cert = member?['cert'] as Map?;
    // Every key file carries its member's certificate (`KeyFile`).
    if (member == null || cert == null) {
      throw const SmsCryptoException(SmsCryptoFailure.badBundle);
    }
    return OpenedKeyFile(
      signed: m['signed'] as Uint8List,
      directory: _directory(m['directory'] as Map),
      own: OwnKey(
        index: member['index'] as int,
        identity: _identity(member),
        cert: _cert(cert),
      ),
    );
  }

  /// Whether [file] is an update file (`update.hku`, `UpdateFile.kt`) rather
  /// than a key file — told by its clear header, so no password is asked
  /// for it.
  static bool isUpdateFile(Uint8List file) {
    const magic = 'HMRKU';
    if (file.length <= magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (file[i] != magic.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// Opens an update file with whichever of [directoryIds] (the directories
  /// this phone holds) it was sealed for, and verifies it against
  /// [anchors]. [SmsCryptoFailure.wrongPassword] when it is for none of
  /// them. It never carries a member key.
  Future<OpenedKeyFile> openUpdateFile({
    required Uint8List file,
    required List<Uint8List> directoryIds,
    required List<Uint8List> anchors,
  }) async {
    final m = await _call<Map>('openUpdateFile', {
      'file': file,
      'directoryIds': directoryIds,
      'anchors': anchors,
    });
    return OpenedKeyFile(
      signed: m['signed'] as Uint8List,
      directory: _directory(m['directory'] as Map),
    );
  }

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
