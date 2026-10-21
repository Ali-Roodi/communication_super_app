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
    required this.number,
    required this.cert,
  });

  /// [SmsIdentity.publicKey] is the certificate and [SmsIdentity.keyId] its
  /// key id — the id every packet names this key by.
  final SmsIdentity identity;

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
  });

  /// What the user called them — an address-book or hidden-phonebook name,
  /// or the number itself. Never anything a key file said.
  final String name;

  /// Canonical, a mobile number (`09…`): the session request goes there.
  final String phone;

  /// The key id the peer's certificate carries once they have answered;
  /// empty before — who holds a number is only known from their answer.
  final String keyId;
  final OwnIdentity own;

  SecurePeer named(String name) =>
      SecurePeer(name: name, phone: phone, keyId: keyId, own: own);
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

/// Answers "which key of ours" and "can this number be written to".
///
/// The key bank holds this phone's own keys and nothing else. Any mobile
/// number can be written to encrypted: the first SMS is a session request
/// carrying our certificate (`CertHandshake`); a phone with هم‌رسان and a key
/// of a trusted authority answers with its own, and from then on the two
/// talk. A phone without one simply never answers. Nobody's key file has to
/// change when someone joins.
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

  /// Every identity this phone holds: one per authority it has a key from.
  Future<List<OwnIdentity>> own() async {
    final cached = _own;
    if (cached != null) return cached;
    final result = <OwnIdentity>[];
    for (final k in await _keyBank.ownKeys()) {
      try {
        final info = await _crypto.certInfo(k.cert);
        result.add(
          OwnIdentity(
            identity: SmsIdentity(
              secret: k.secret,
              publicKey: k.cert,
              keyId: info.keyId,
            ),
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

  /// The certificate we present to a number we have not talked to yet: the
  /// first key we hold, null without any.
  Future<OwnIdentity?> ownCert() async => (await own()).firstOrNull;

  /// How to reach [phone] (canonical) encrypted, as [name]: over our
  /// certificate, to whoever holds the number. Null when [phone] is not a
  /// mobile (a landline cannot receive the handshake), is one of our own
  /// numbers, or this phone holds no key.
  Future<SecurePeer?> forNumber(String phone, {String? name}) async {
    if (!phone.startsWith('09') || phone.length != 11) return null;
    final mine = await ownCert();
    if (mine == null) return null;
    if ((await own()).any((o) => o.number == phone)) return null;
    return SecurePeer(name: name ?? phone, phone: phone, keyId: '', own: mine);
  }
}
