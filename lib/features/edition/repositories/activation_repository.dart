import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/edition/activation_code.dart';
import '../services/device_identity_service.dart';

/// Whether this install has unlocked the inter-organizational edition.
///
/// What is stored is the **activation code itself**, not an "activated" flag,
/// and it is re-verified against the device's own identity on every read. So
/// the state cannot be forged by writing a boolean, and it does not travel:
/// storage copied to another phone — or left behind by a factory reset, which
/// regenerates ANDROID_ID — fails the check and reads as not activated.
class ActivationRepository {
  ActivationRepository({
    DeviceIdentityService? identity,
    FlutterSecureStorage? storage,
  }) : _identity = identity ?? DeviceIdentityService(),
       _storage = storage ?? const FlutterSecureStorage();

  final DeviceIdentityService _identity;
  final FlutterSecureStorage _storage;

  /// The 6-character code the user reads to the mentor, or null when the
  /// device has no identity to derive it from.
  Future<String?> deviceCode() async {
    final androidId = await _identity.androidId();
    return androidId == null ? null : ActivationCode.deviceCodeFor(androidId);
  }

  /// True only while a stored code verifies against this device.
  Future<bool> isActivated() async {
    final stored = await _readStored();
    if (stored == null) return false;
    final device = await deviceCode();
    if (device == null) return false;
    return ActivationCode.matches(deviceCode: device, input: stored);
  }

  /// Stores [input] when it is this device's activation code.
  ///
  /// Returns false — and stores nothing — for a wrong code or a device with no
  /// identity. The stored form is the normalized code, so what is re-verified
  /// later is exactly what was verified now.
  Future<bool> activate(String input) async {
    final device = await deviceCode();
    if (device == null) return false;
    final code = ActivationCode.normalize(input);
    if (code == null ||
        !ActivationCode.matches(deviceCode: device, input: code)) {
      return false;
    }
    await _storage.write(key: AppConstants.interOrgActivationKey, value: code);
    return true;
  }

  Future<void> deactivate() =>
      _storage.delete(key: AppConstants.interOrgActivationKey);

  /// A storage failure (a Keystore key invalidated by a restore, say) reads as
  /// "not activated": the user can enter the code again, whereas guessing
  /// "activated" would unlock an edition on no evidence at all.
  Future<String?> _readStored() async {
    try {
      return await _storage.read(key: AppConstants.interOrgActivationKey);
    } catch (e) {
      debugPrint('Activation code unreadable: $e');
      return null;
    }
  }
}
