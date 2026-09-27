import 'package:flutter/services.dart';

/// Why a vault operation failed. Mirrors the error codes of
/// `android/.../secure/SecureVaultHandler.kt`.
enum VaultFailure {
  /// There is no vault to open.
  noVault,

  /// The PIN does not open the vault.
  wrongPin,

  /// The Keystore key that seals the vault is gone — the vault (and the data
  /// it protects) can only be reset.
  keyLost,

  /// The vault file is unreadable.
  corrupt,

  /// `create` on a device that already has a vault.
  alreadyExists,

  /// Anything else (I/O, a platform error).
  failed,
}

class VaultException implements Exception {
  const VaultException(this.failure);
  final VaultFailure failure;

  static VaultFailure _fromCode(String code) => switch (code) {
    'NO_VAULT' => VaultFailure.noVault,
    'WRONG_PIN' => VaultFailure.wrongPin,
    'VAULT_KEY_LOST' => VaultFailure.keyLost,
    'VAULT_CORRUPT' => VaultFailure.corrupt,
    'ALREADY_EXISTS' => VaultFailure.alreadyExists,
    _ => VaultFailure.failed,
  };

  @override
  String toString() => 'VaultException($failure)';
}

/// The secure section's key vault, over `…/secure_vault`.
///
/// The data key comes back as hex: the database is opened from Dart
/// (SQLCipher), so the key has to cross once per unlock. It is never written
/// anywhere in clear — see `SecureVaultHandler`.
class SecureVaultService {
  const SecureVaultService();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/secure_vault',
  );

  Future<bool> exists() async => await _call<bool>('exists', const {}) ?? false;

  /// A new vault sealed under [pin]; returns its data key (hex).
  Future<String> create(String pin) async =>
      (await _call<String>('create', {'pin': pin}))!;

  /// The data key (hex) — [VaultFailure.wrongPin] for a wrong [pin].
  Future<String> unlock(String pin) async =>
      (await _call<String>('unlock', {'pin': pin}))!;

  /// Re-seals the same data key under [newPin]. The database itself is not
  /// touched, so this is instant whatever is stored.
  Future<void> rekey(String oldPin, String newPin) =>
      _call<bool>('rekey', {'oldPin': oldPin, 'newPin': newPin});

  /// Deletes the vault and its Keystore key. What it protected is gone after.
  Future<void> destroy() => _call<bool>('destroy', const {});

  /// FLAG_SECURE on the activity window: no screenshots, no screen recording,
  /// a blank thumbnail in recents.
  Future<void> setSecureWindow(bool secure) async {
    try {
      await _channel.invokeMethod<bool>('setSecureWindow', {'secure': secure});
    } on PlatformException {
      // Best effort: a missing window must not break locking or unlocking.
    } on MissingPluginException {
      // Tests and non-Android hosts.
    }
  }

  Future<T?> _call<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw VaultException(VaultException._fromCode(e.code));
    } on MissingPluginException {
      throw const VaultException(VaultFailure.failed);
    }
  }
}
