import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

/// One of this phone's identities: the key a key file gave it, with the
/// member certificate that names it.
class OwnIdentity {
  const OwnIdentity({
    required this.identity,
    required this.directoryId,
    required this.number,
    required this.cert,
  });

  /// [SmsIdentity.publicKey] is the certificate and [SmsIdentity.keyId] its
  /// key id — the id every packet and directory names this key by.
  final SmsIdentity identity;

  /// The directory of the key file it came from (hex).
  final String directoryId;

  /// The number the certificate names (canonical, `09…`).
  final String number;

  /// The member certificate (`MemberCert`), 103 bytes.
  final Uint8List cert;

  String get keyId => keyHex(identity.keyId);
}

/// Someone an encrypted conversation can be held with, and the identity of
/// ours that talks to them.
class SecurePeer {
  const SecurePeer({
    required this.name,
    required this.phone,
    required this.keyId,
    required this.own,
    this.sourceName,
  });

  final String name;

  /// Canonical, a mobile number (`09…`): the session request goes there.
  final String phone;

  /// The key id the peer's certificate will carry — known in advance for a
  /// member of our directory, empty for a number the user typed.
  final String keyId;

  /// The organization's name, for the picker.
  final String? sourceName;
  final OwnIdentity own;

  String get directoryId => own.directoryId;
}

/// The key id a member certificate for the X25519 key at the end of
/// [publicKey] carries. Mirrors `MemberCert.keyIdOf`
/// (`smscrypto/keybank/MemberCert.kt`): SHA-256 of the label and the X25519
/// key, first 8 bytes.
String certKeyIdFor(Uint8List publicKey) {
  final x25519 = publicKey.sublist(publicKey.length - 32);
  final digest = sha256.convert([
    ...ascii.encode('hamresan.sms.cert-key-id.v1'),
    ...x25519,
  ]);
  return keyHex(digest.bytes.sublist(0, 8));
}

/// Answers "who is this" and "which key of ours" from the key bank.
///
/// Every own key comes with its member certificate, and every conversation is
/// made over the certificate handshake: two SMS parts each way, and a member
/// the authority added after our directory was issued is reachable too
/// ([forTypedNumber]). The directory is the list of colleagues and what their
/// certificates are expected to name.
class SecureIdentities {
  SecureIdentities({
    KeyBankRepository? keyBank,
    SmsCryptoService crypto = const SmsCryptoService(),
  }) : _keyBank = keyBank ?? KeyBankRepository(),
       _crypto = crypto;

  final KeyBankRepository _keyBank;
  final SmsCryptoService _crypto;

  List<OwnIdentity>? _own;

  /// Drops everything cached (the key bank changed, or the section closed).
  void reset() {
    _own = null;
  }

  /// Every identity this phone holds: one per imported key file.
  Future<List<OwnIdentity>> own() async {
    final cached = _own;
    if (cached != null) return cached;
    final result = <OwnIdentity>[];
    for (final k in await _keyBank.ownDirectoryKeys()) {
      try {
        final info = await _crypto.certInfo(k.cert);
        result.add(
          OwnIdentity(
            identity: SmsIdentity(
              secret: k.identity.secret,
              publicKey: k.cert,
              keyId: info.keyId,
            ),
            directoryId: k.directoryId,
            number: info.phone,
            cert: k.cert,
          ),
        );
      } on SmsCryptoException catch (e) {
        debugPrint('A stored certificate does not parse: ${e.failure.name}');
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

  /// The identity of ours for [directoryId], if this phone has one.
  Future<OwnIdentity?> _ownFor(String directoryId) async {
    for (final o in await own()) {
      if (o.directoryId == directoryId) return o;
    }
    return null;
  }

  /// The certificate we present to [phone] (canonical): the one of a
  /// directory that lists them, else the first we have; null without any.
  Future<OwnIdentity?> ownCert({String? phone}) async {
    final all = await own();
    if (all.isEmpty) return null;
    if (phone != null) {
      for (final k in await _keyBank.directoryKeysFor(phone)) {
        final mine = await _ownFor(k.directoryId);
        if (mine != null) return mine;
      }
    }
    return all.first;
  }

  /// The number an encrypted SMS to someone listed with [phones] goes to:
  /// the first mobile (`09…`) — what their certificate names. Null when
  /// none is a mobile: a landline cannot receive the handshake.
  static String? textTarget(List<String> phones) =>
      phones.where((p) => p.startsWith('09')).firstOrNull;

  /// Everyone this phone could start an encrypted conversation with: every
  /// member (but ourselves) of every directory we hold a key of.
  Future<List<SecurePeer>> directoryPeers() async {
    final ownKeys = {for (final o in await own()) o.keyId};
    final peers = <SecurePeer>[];
    for (final m in await _keyBank.allMembers()) {
      if (ownKeys.contains(m.keyId)) continue;
      final phone = textTarget(m.phones);
      if (phone == null) continue;
      final mine = await _ownFor(m.directoryId);
      if (mine == null) continue;
      peers.add(
        SecurePeer(
          name: m.name,
          phone: phone,
          keyId: m.keyId,
          sourceName: m.directoryName,
          own: mine,
        ),
      );
    }
    return peers;
  }

  /// The ways to reach [phone] (canonical): the directory members who own
  /// the number, one per directory we hold a key of.
  ///
  /// A number the directories do not list is **not** offered here: whoever
  /// is behind it may not be a member at all, and would get an unreadable
  /// SMS. Only a number the user typed for an encrypted conversation is —
  /// see [forTypedNumber].
  Future<List<SecurePeer>> forNumber(String phone) async {
    if (!phone.startsWith('09')) return const [];
    final peers = <SecurePeer>[];
    for (final k in await _keyBank.directoryKeysFor(phone)) {
      final mine = await _ownFor(k.directoryId);
      if (mine == null || mine.keyId == keyHex(k.keyId)) continue;
      peers.add(
        SecurePeer(
          name: k.name,
          phone: phone,
          keyId: keyHex(k.keyId),
          sourceName: k.directoryName,
          own: mine,
        ),
      );
    }
    return peers;
  }

  /// [forNumber], plus — for a mobile number no directory lists — a request
  /// to whoever holds it: a member the authority added after our directory
  /// was issued answers with their own certificate, and nobody's phone
  /// needed anything new. Who they are is known once they answer.
  Future<List<SecurePeer>> forTypedNumber(String phone) async {
    final peers = await forNumber(phone);
    if (peers.isNotEmpty || !phone.startsWith('09')) return peers;
    final mine = await ownCert(phone: phone);
    if (mine == null || mine.number == phone) return peers;
    return [SecurePeer(name: phone, phone: phone, keyId: '', own: mine)];
  }

  /// What the directories call the holder of [phone], if any.
  Future<String?> nameFor(String phone) => _keyBank.nameFor(phone);
}
