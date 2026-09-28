import 'package:flutter/foundation.dart';

import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/services/hidden_bridge.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

/// The secure section's own key pair (ML-KEM-768 + X25519), which Kotlin
/// seals hidden-phonebook records to while the section is locked
/// (`SealedBox`). The secret lives only in `secure.db` (`secure_meta`); the
/// public half is handed to Kotlin, which keeps it in plain storage — it is
/// public.
///
/// Made on first use. A new section (after a reset) gets a new pair, so
/// records sealed to the old one simply do not open, and are dropped.
class SealingKey {
  SealingKey({
    SecureMessageStore? store,
    SmsCryptoService crypto = const SmsCryptoService(),
    HiddenBridge bridge = const HiddenBridge(),
  }) : _store = store ?? SecureMessageStore(),
       _crypto = crypto,
       _bridge = bridge;

  final SecureMessageStore _store;
  final SmsCryptoService _crypto;
  final HiddenBridge _bridge;

  static const metaKey = 'sealing_identity';

  /// The secret, or null when none was made yet (nothing can have been
  /// sealed to it then).
  Future<Uint8List?> secret() async {
    final hex = await _store.meta(metaKey);
    return hex == null ? null : _unhex(hex);
  }

  /// Makes the pair if needed and (re)tells Kotlin the public half —
  /// cheap, and it repairs a Kotlin side whose storage was cleared.
  Future<Uint8List> ensure() async {
    var secret = await this.secret();
    final Uint8List publicKey;
    if (secret == null) {
      final made = await _crypto.generateIdentity();
      await _store.setMeta(metaKey, _hex(made.secret));
      secret = made.secret;
      publicKey = made.publicKey;
    } else {
      publicKey = (await _crypto.publicIdentity(secret)).publicKey;
    }
    await _bridge.setSealingKey(publicKey);
    return secret;
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
