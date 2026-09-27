import 'package:flutter/foundation.dart';

import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

/// One of this phone's identities, and which key-bank entry it comes from.
class OwnIdentity {
  const OwnIdentity({
    required this.identity,
    required this.source,
    this.number,
  });
  final SmsIdentity identity;

  /// `directory:<id>` or `group:<id>`.
  final String source;

  /// For a group identity: the own number it was derived from.
  final String? number;

  String get keyId => keyHex(identity.keyId);
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
  final Uint8List publicKey;
  final String keyId;
  final String source;

  /// The directory's or group's name, for the picker.
  final String? sourceName;
  final OwnIdentity own;
}

/// Answers "who is this key" and "which key of ours" from the key bank.
///
/// Directory identities are stored; group identities are derived (a group
/// member's key is a function of the group seed and the number), so they are
/// computed on demand and cached for as long as this object lives — one open
/// session of the secure section.
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

  /// Every identity this phone holds: its directory keys, and its registered
  /// numbers in every passphrase group.
  Future<List<OwnIdentity>> own() async {
    final cached = _own;
    if (cached != null) return cached;
    final result = <OwnIdentity>[
      for (final k in await _keyBank.ownDirectoryKeys())
        OwnIdentity(identity: k.identity, source: 'directory:${k.directoryId}'),
    ];
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

  /// The number an encrypted SMS to someone listed with [phones] goes to:
  /// the first mobile (`09…`), because a landline cannot receive an SMS;
  /// the first number when none is mobile.
  static String textTarget(List<String> phones) =>
      phones.firstWhere((p) => p.startsWith('09'), orElse: () => phones.first);

  /// Everyone this phone could start an encrypted conversation with: every
  /// directory member (but ourselves) whose directory holds a key of ours.
  /// Passphrase groups have no member list — see [forNumber].
  Future<List<SecurePeer>> directoryPeers() async {
    final ownKeys = {for (final o in await own()) o.keyId};
    final peers = <SecurePeer>[];
    for (final m in await _keyBank.allMembers()) {
      if (ownKeys.contains(m.keyId) || m.phones.isEmpty) continue;
      final own = await _ownFor('directory:${m.directoryId}');
      if (own == null) continue;
      peers.add(
        SecurePeer(
          name: m.name,
          phone: textTarget(m.phones),
          publicKey: m.publicKey,
          keyId: m.keyId,
          source: 'directory:${m.directoryId}',
          sourceName: m.directoryName,
          own: own,
        ),
      );
    }
    return peers;
  }

  /// The ways to reach [phone] (canonical): directory members who own the
  /// number, and the number's key in every passphrase group we can use.
  Future<List<SecurePeer>> forNumber(String phone) async {
    final peers = <SecurePeer>[];
    for (final k in await _keyBank.directoryKeysFor(phone)) {
      final own = await _ownFor(k.source);
      if (own == null) continue;
      peers.add(
        SecurePeer(
          name: k.name,
          phone: phone,
          publicKey: k.publicKey,
          keyId: keyHex(k.keyId),
          source: k.source,
          own: own,
        ),
      );
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
