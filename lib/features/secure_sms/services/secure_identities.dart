import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

/// One of this phone's identities, and which key-bank entry it comes from.
class OwnIdentity {
  const OwnIdentity({
    required this.identity,
    required this.source,
    this.number,
    this.cert,
  });

  /// For a certificate identity, [SmsIdentity.publicKey] is the certificate
  /// and [SmsIdentity.keyId] its key id.
  final SmsIdentity identity;

  /// `directory:<id>`, `group:<id>`, or `cert:<directory id>` — the same
  /// directory key, reached over the certificate handshake.
  final String source;

  /// For a group identity: the own number it was derived from; for a
  /// certificate: the number it names.
  final String? number;

  /// The member certificate (`MemberCert`), for a `cert:` identity.
  final Uint8List? cert;

  String get keyId => keyHex(identity.keyId);

  bool get isCert => cert != null;
}

/// Someone an encrypted conversation can be held with, and the identity of
/// ours that talks to them.
class SecurePeer {
  const SecurePeer({
    required this.name,
    required this.phone,
    required this.publicKey,
    required this.keyId,
    required this.source,
    required this.own,
    this.sourceName,
  });

  final String name;

  /// Canonical.
  final String phone;

  /// Empty for a certificate peer: its certificate comes with its first
  /// answer, and nothing is needed before.
  final Uint8List publicKey;

  /// For a certificate peer, the key id its certificate will carry — known
  /// in advance for a member of our directory, empty for anybody else.
  final String keyId;
  final String source;

  /// The directory's or group's name, for the picker.
  final String? sourceName;
  final OwnIdentity own;

  bool get isCert => source.startsWith('cert:');
}

/// The key id a member certificate for the directory key [publicKey] will
/// carry. Mirrors `MemberCert.keyIdOf` (`smscrypto/keybank/MemberCert.kt`):
/// SHA-256 of the label and the X25519 key — the last 32 bytes of a
/// published identity — first 8 bytes.
String certKeyIdFor(Uint8List publicKey) {
  final x25519 = publicKey.sublist(publicKey.length - 32);
  final digest = sha256.convert([
    ...ascii.encode('hamresan.sms.cert-key-id.v1'),
    ...x25519,
  ]);
  return keyHex(digest.bytes.sublist(0, 8));
}

/// Answers "who is this key" and "which key of ours" from the key bank.
///
/// Directory identities are stored; group identities are derived (a group
/// member's key is a function of the group seed and the number), so they are
/// computed on demand and cached for as long as this object lives — one open
/// session of the secure section.
///
/// **Certificates first.** A directory key imported with its member
/// certificate is offered as a `cert:` identity as well, and every peer of
/// that directory is reached over the certificate handshake: two SMS parts
/// each way instead of ten and eleven, and a member the authority added
/// after our directory was issued is reachable too ([forTypedNumber]).
class SecureIdentities {
  SecureIdentities({
    KeyBankRepository? keyBank,
    SmsCryptoService crypto = const SmsCryptoService(),
  }) : _keyBank = keyBank ?? KeyBankRepository(),
       _crypto = crypto;

  final KeyBankRepository _keyBank;
  final SmsCryptoService _crypto;

  final Map<String, SmsIdentity> _derived = {};
  List<OwnIdentity>? _own;

  /// Drops everything cached (the key bank changed, or the section closed).
  void reset() {
    _derived.clear();
    _own = null;
  }

  Future<SmsIdentity> _groupMember(
    String groupId,
    Uint8List seed,
    String phone,
  ) async {
    final key = '$groupId/$phone';
    return _derived[key] ??= await _crypto.groupMember(
      group: seed,
      phone: phone,
    );
  }

  /// Every identity this phone holds: its directory keys (and their
  /// certificates), and its registered numbers in every passphrase group.
  Future<List<OwnIdentity>> own() async {
    final cached = _own;
    if (cached != null) return cached;
    final result = <OwnIdentity>[];
    for (final k in await _keyBank.ownDirectoryKeys()) {
      result.add(
        OwnIdentity(identity: k.identity, source: 'directory:${k.directoryId}'),
      );
      final cert = k.cert;
      if (cert == null) continue;
      try {
        final info = await _crypto.certInfo(cert);
        result.add(
          OwnIdentity(
            identity: SmsIdentity(
              secret: k.identity.secret,
              publicKey: cert,
              keyId: info.keyId,
            ),
            source: 'cert:${k.directoryId}',
            number: info.phone,
            cert: cert,
          ),
        );
      } on SmsCryptoException catch (e) {
        debugPrint('A stored certificate does not parse: ${e.failure.name}');
      }
    }
    final numbers = (await _keyBank.snapshot()).ownNumbers;
    for (final g in await _keyBank.groupSeeds()) {
      for (final n in numbers) {
        result.add(
          OwnIdentity(
            identity: await _groupMember(g.id, g.seed, n),
            source: 'group:${g.id}',
            number: n,
          ),
        );
      }
    }
    return _own = result;
  }

  Future<OwnIdentity?> ownByKeyId(String keyId) async {
    for (final o in await own()) {
      if (o.keyId == keyId) return o;
    }
    return null;
  }

  /// The identity of ours for a key-bank [source], if this phone has one.
  Future<OwnIdentity?> _ownFor(String source) async {
    for (final o in await own()) {
      if (o.source == source) return o;
    }
    return null;
  }

  /// The certificate we present to [phone] (canonical): the one of a
  /// directory that lists them, else the first we have; null without any.
  Future<OwnIdentity?> ownCert({String? phone}) async {
    final certs = [
      for (final o in await own())
        if (o.isCert) o,
    ];
    if (certs.isEmpty) return null;
    if (phone != null) {
      for (final k in await _keyBank.directoryKeysFor(phone)) {
        final dir = k.source.substring('directory:'.length);
        for (final c in certs) {
          if (c.source == 'cert:$dir') return c;
        }
      }
    }
    return certs.first;
  }

  /// The number an encrypted SMS to someone listed with [phones] goes to:
  /// the first mobile (`09…`), because a landline cannot receive an SMS;
  /// the first number when none is mobile.
  static String textTarget(List<String> phones) =>
      phones.firstWhere((p) => p.startsWith('09'), orElse: () => phones.first);

  /// Everyone this phone could start an encrypted conversation with: every
  /// directory member (but ourselves) whose directory holds a key of ours —
  /// over the certificate handshake when that key came with a certificate.
  /// Passphrase groups have no member list — see [forNumber].
  Future<List<SecurePeer>> directoryPeers() async {
    final ownKeys = {for (final o in await own()) o.keyId};
    final peers = <SecurePeer>[];
    for (final m in await _keyBank.allMembers()) {
      if (ownKeys.contains(m.keyId) || m.phones.isEmpty) continue;
      final peer = await _directoryPeer(
        directoryId: m.directoryId,
        directoryName: m.directoryName,
        name: m.name,
        phone: textTarget(m.phones),
        publicKey: m.publicKey,
        keyId: m.keyId,
      );
      if (peer != null) peers.add(peer);
    }
    return peers;
  }

  /// A directory member as a peer: over our certificate for that directory
  /// when we have one, else over the directory key itself.
  Future<SecurePeer?> _directoryPeer({
    required String directoryId,
    String? directoryName,
    required String name,
    required String phone,
    required Uint8List publicKey,
    required String keyId,
  }) async {
    final cert = await _ownFor('cert:$directoryId');
    // A member without a mobile number has no certificate to answer with.
    if (cert != null && phone.startsWith('09')) {
      return SecurePeer(
        name: name,
        phone: phone,
        publicKey: Uint8List(0),
        keyId: certKeyIdFor(publicKey),
        source: cert.source,
        sourceName: directoryName,
        own: cert,
      );
    }
    final own = await _ownFor('directory:$directoryId');
    if (own == null) return null;
    return SecurePeer(
      name: name,
      phone: phone,
      publicKey: publicKey,
      keyId: keyId,
      source: 'directory:$directoryId',
      sourceName: directoryName,
      own: own,
    );
  }

  /// The ways to reach [phone] (canonical): directory members who own the
  /// number, and the number's key in every passphrase group we can use.
  ///
  /// A number the directories do not list is **not** offered over a
  /// certificate here: whoever is behind it may not be a member at all, and
  /// would get an unreadable SMS. Only a number the user typed for an
  /// encrypted conversation is — see [forTypedNumber].
  Future<List<SecurePeer>> forNumber(String phone) async {
    final peers = <SecurePeer>[];
    for (final k in await _keyBank.directoryKeysFor(phone)) {
      final peer = await _directoryPeer(
        directoryId: k.source.substring('directory:'.length),
        name: k.name,
        phone: phone,
        publicKey: k.publicKey,
        keyId: keyHex(k.keyId),
      );
      if (peer != null) peers.add(peer);
    }
    for (final g in await _keyBank.groupSeeds()) {
      final own = await _ownFor('group:${g.id}');
      if (own == null) continue;
      final member = await _groupMember(g.id, g.seed, phone);
      peers.add(
        SecurePeer(
          name: phone,
          phone: phone,
          publicKey: member.publicKey,
          keyId: keyHex(member.keyId),
          source: 'group:${g.id}',
          sourceName: g.name,
          own: own,
        ),
      );
    }
    return peers;
  }

  /// [forNumber], plus — for a mobile number no directory lists — the
  /// certificate handshake: a member the authority added after our
  /// directory was issued answers with their own certificate, and nobody's
  /// phone needed anything new. Who they are is known once they answer.
  Future<List<SecurePeer>> forTypedNumber(String phone) async {
    final peers = await forNumber(phone);
    if (peers.any((p) => p.isCert) || !phone.startsWith('09')) return peers;
    final cert = await ownCert(phone: phone);
    if (cert == null || cert.number == phone) return peers;
    return [
      SecurePeer(
        name: phone,
        phone: phone,
        publicKey: Uint8List(0),
        keyId: '',
        source: cert.source,
        own: cert,
      ),
      ...peers,
    ];
  }

  /// What the directories call the holder of [phone], if any.
  Future<String?> nameFor(String phone) => _keyBank.nameFor(phone);

  /// Who sent a session request: the key [keyId] (a directory member, whatever
  /// number they wrote from) or the number [phone]'s key in a group.
  Future<SecurePeer?> byKeyId(String keyId, String phone) async {
    for (final m in await _keyBank.allMembers()) {
      if (m.keyId != keyId) continue;
      final own = await _ownFor('directory:${m.directoryId}');
      if (own == null) return null;
      return SecurePeer(
        name: m.name,
        phone: phone,
        publicKey: m.publicKey,
        keyId: m.keyId,
        source: 'directory:${m.directoryId}',
        own: own,
      );
    }
    for (final p in await forNumber(phone)) {
      if (p.keyId == keyId) return p;
    }
    return null;
  }
}
