import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the phone can offer for biometric unlock — `BiometricGate.status`.
enum BiometricAvailability {
  available,

  /// A reader exists but nothing is enrolled on the phone.
  noneEnrolled,

  /// The phone has no screen lock at all.
  noDeviceLock,

  /// Present but not usable right now (busy, temporarily off).
  unavailable,

  /// Android 8 or older, or no biometric hardware.
  unsupported,
}

/// How a biometric prompt ended — `BiometricGate.authenticate`.
enum BiometricPromptResult {
  success,

  /// Dismissed, or «ورود با رمز» chosen.
  cancelled,

  /// Too many failed tries; the phone itself locks biometrics for a while.
  lockout,

  /// Locked until the phone is unlocked with its own PIN.
  lockoutPermanent,
  noneEnrolled,
  unavailable,

  /// Another prompt is already up.
  busy,
  error,
}

/// The enrollment-change sentinel — `BiometricGate.sentinelState`.
enum SentinelState { valid, invalidated, absent }

/// Channel `…/app_lock` (`AppLockHandler`). Every call is fail-safe: an
/// exception answers the most conservative value, never throws to the UI.
class AppLockPlatform {
  AppLockPlatform._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/app_lock',
  );

  static Future<BiometricAvailability> biometricStatus() async {
    try {
      final status = await _channel.invokeMethod<String>('biometricStatus');
      return switch (status) {
        'available' => BiometricAvailability.available,
        'none_enrolled' => BiometricAvailability.noneEnrolled,
        'no_lock' => BiometricAvailability.noDeviceLock,
        'unavailable' => BiometricAvailability.unavailable,
        _ => BiometricAvailability.unsupported,
      };
    } catch (e) {
      debugPrint('biometricStatus failed: $e');
      return BiometricAvailability.unsupported;
    }
  }

  static Future<BiometricPromptResult> authenticate({
    required String title,
    required String subtitle,
    required String negative,
  }) async {
    try {
      final outcome = await _channel.invokeMethod<String>('authenticate', {
        'title': title,
        'subtitle': subtitle,
        'negative': negative,
      });
      return switch (outcome) {
        'success' => BiometricPromptResult.success,
        'cancelled' => BiometricPromptResult.cancelled,
        'lockout' => BiometricPromptResult.lockout,
        'lockout_permanent' => BiometricPromptResult.lockoutPermanent,
        'none_enrolled' => BiometricPromptResult.noneEnrolled,
        'unavailable' || 'unsupported' => BiometricPromptResult.unavailable,
        'busy' => BiometricPromptResult.busy,
        _ => BiometricPromptResult.error,
      };
    } catch (e) {
      debugPrint('biometric authenticate failed: $e');
      return BiometricPromptResult.error;
    }
  }

  /// Takes down a prompt still on screen; it then answers `cancelled`.
  static Future<void> cancelAuthentication() async {
    try {
      await _channel.invokeMethod<void>('cancelAuthentication');
    } catch (e) {
      debugPrint('cancelAuthentication failed: $e');
    }
  }

  static Future<bool> createSentinel() async {
    try {
      return await _channel.invokeMethod<bool>('createSentinel') ?? false;
    } catch (e) {
      debugPrint('createSentinel failed: $e');
      return false;
    }
  }

  static Future<SentinelState> sentinelState() async {
    try {
      final state = await _channel.invokeMethod<String>('sentinelState');
      return switch (state) {
        'invalidated' => SentinelState.invalidated,
        'absent' => SentinelState.absent,
        _ => SentinelState.valid,
      };
    } catch (e) {
      debugPrint('sentinelState failed: $e');
      return SentinelState.valid;
    }
  }

  static Future<void> deleteSentinel() async {
    try {
      await _channel.invokeMethod<void>('deleteSentinel');
    } catch (e) {
      debugPrint('deleteSentinel failed: $e');
    }
  }

  static Future<void> setHideNotificationContent(bool value) async {
    try {
      await _channel.invokeMethod<void>('setHideNotificationContent', {
        'value': value,
      });
    } catch (e) {
      debugPrint('setHideNotificationContent failed: $e');
    }
  }

  /// The app lock is open: notifications show their content until it locks
  /// again — at once if the app is on screen, otherwise after [graceSeconds]
  /// («قفل خودکار»), counted natively from when it left (`AppLockSession`).
  static Future<void> sessionUnlocked(int graceSeconds) async {
    try {
      await _channel.invokeMethod<void>('sessionUnlocked', {
        'graceSeconds': graceSeconds,
      });
    } catch (e) {
      debugPrint('sessionUnlocked failed: $e');
    }
  }

  /// The app lock closed: notifications hide their content again, and the
  /// ones already up are folded.
  static Future<void> sessionLocked() async {
    try {
      await _channel.invokeMethod<void>('sessionLocked');
    } catch (e) {
      debugPrint('sessionLocked failed: $e');
    }
  }
}
