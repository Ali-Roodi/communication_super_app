import 'package:flutter/services.dart';

import 'package:communication_super_app/features/authentication/services/app_lock_platform.dart';

export 'package:communication_super_app/features/authentication/services/app_lock_platform.dart'
    show BiometricAvailability;

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

  /// The biometric prompt was dismissed, or «با رمز» chosen.
  bioCancelled,

  /// Too many tries; the phone locked its biometrics for a while.
  bioLockedOut,

  /// A biometric was enrolled (or all removed, or the phone lock turned off)
  /// since the copy was made. The copy is deleted; only the PIN opens now.
  bioInvalidated,

  /// There is no biometric copy (never turned on, or turned off).
  bioOff,

  /// The phone cannot show a strong-biometric prompt right now.
  bioUnavailable,

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
    'BIO_CANCELLED' || 'BIO_BUSY' => VaultFailure.bioCancelled,
    'BIO_LOCKOUT' || 'BIO_LOCKOUT_PERMANENT' => VaultFailure.bioLockedOut,
    // Nothing enrolled any more: the system destroyed the key with the last
    // finger, so the copy is as gone as after a new enrollment.
    'BIO_INVALIDATED' || 'BIO_NONE_ENROLLED' => VaultFailure.bioInvalidated,
    'BIO_OFF' => VaultFailure.bioOff,
    'BIO_UNAVAILABLE' ||
    'BIO_UNSUPPORTED' ||
    'BIO_ERROR' => VaultFailure.bioUnavailable,
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

  /// Deletes the vault, its biometric copy and their Keystore keys. What it
  /// protected is gone after.
  Future<void> destroy() => _call<bool>('destroy', const {});

  /// Whether the phone can offer a **strong** biometric — the only kind that
  /// can release a Keystore key (most face unlocks cannot).
  Future<BiometricAvailability> biometricStatus() async {
    try {
      final status = await _channel.invokeMethod<String>('bioStatus');
      return switch (status) {
        'available' => BiometricAvailability.available,
        'none_enrolled' => BiometricAvailability.noneEnrolled,
        'no_lock' => BiometricAvailability.noDeviceLock,
        'unavailable' => BiometricAvailability.unavailable,
        _ => BiometricAvailability.unsupported,
      };
    } catch (_) {
      return BiometricAvailability.unsupported;
    }
  }

  /// Whether the biometric copy of the data key exists.
  Future<bool> biometricEnabled() async {
    try {
      return await _call<bool>('bioEnabled', const {}) ?? false;
    } on VaultException {
      return false;
    }
  }

  /// Makes the biometric copy: [pin] opens the vault, then a strong biometric
  /// prompt authorises the key that seals the copy.
  Future<void> enableBiometric(String pin) => _call<bool>('bioEnable', {
    'pin': pin,
    'title': 'باز کردن بخش امن با اثر انگشت',
    'subtitle': 'برای فعال کردن، اثر انگشت خود را تأیید کنید',
    'negative': 'انصراف',
  });

  /// The data key (hex), released by a strong biometric.
  Future<String> unlockWithBiometric() async =>
      (await _call<String>('bioUnlock', const {
        'title': 'باز کردن بخش امن',
        'subtitle': 'با اثر انگشتی که روی گوشی ثبت کرده‌اید',
        'negative': 'با رمز',
      }))!;

  Future<void> disableBiometric() => _call<bool>('bioDisable', const {});

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
