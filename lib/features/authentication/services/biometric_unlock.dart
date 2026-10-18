import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/services/app_handoff.dart';
import '../models/auth_type.dart';
import '../repositories/auth_repository.dart';
import 'app_lock_platform.dart';

/// How [BiometricUnlock.unlock] ended.
enum BiometricUnlockOutcome {
  /// The app may open.
  unlocked,

  /// The user dismissed the prompt or chose the PIN.
  cancelled,

  /// The setting is off, or there is no PIN.
  notEnabled,

  /// The phone cannot show a prompt right now; the PIN still works.
  unavailable,

  /// The phone's fingerprints or face changed (or its lock was removed) since
  /// the setting was turned on. The setting has been switched off.
  enrollmentChanged,

  /// Too many tries; the phone locked its biometrics for a while.
  lockedOut,
  failed,
}

/// How [BiometricUnlock.enable] ended.
enum BiometricEnableOutcome {
  enabled,
  cancelled,
  noneEnrolled,
  noDeviceLock,
  unsupported,
  failed,
}

/// «باز کردن با اثر انگشت یا چهره» — the phone's own biometric, in place of
/// typing the app PIN, on the launch PIN screen and on «قفل خودکار».
///
/// - It opens the **app lock only**. The secure section is sealed under the
///   PIN itself, so it keeps asking for the PIN — a fingerprint has nothing to
///   open it with (see `BiometricGate`).
/// - It needs a PIN: it is an alternative way past the PIN, never instead of
///   having one. Removing or recovering the PIN removes it
///   (`AuthRepository.clearAuth`).
/// - A fingerprint or face added to the phone after it was switched on turns
///   it off ([BiometricUnlockOutcome.enrollmentChanged]) — otherwise anyone
///   who knows the *phone's* PIN could enrol their own finger and walk in.
/// - It is never the phone's PIN or pattern: the prompt accepts biometrics
///   only, with «ورود با رمز» as its way out.
class BiometricUnlock {
  BiometricUnlock({FlutterSecureStorage? storage, AuthRepository? auth})
    : _storage = storage ?? const FlutterSecureStorage(),
      _auth = auth ?? AuthRepository();

  final FlutterSecureStorage _storage;
  final AuthRepository _auth;

  static const String _unlockTitle = 'باز کردن قفل هم‌رسان';
  static const String _subtitle =
      'با اثر انگشت یا چهره‌ای که روی گوشی ثبت کرده‌اید';
  static const String _negative = 'ورود با رمز';

  /// Whether the switch is on and there is a PIN for it to stand in for.
  Future<bool> isEnabled() async {
    if (await _storage.read(key: AppConstants.biometricUnlockKey) != 'true') {
      return false;
    }
    return await _auth.getAuthType() == AuthType.pin;
  }

  /// Shows the prompt over a lock screen. Never throws.
  Future<BiometricUnlockOutcome> unlock() async {
    try {
      if (!await isEnabled()) return BiometricUnlockOutcome.notEnabled;

      if (await _storage.read(key: AppConstants.biometricSentinelKey) ==
          'true') {
        // absent counts as changed: on some phones the system deletes an
        // invalidated key outright instead of keeping it unusable.
        if (await AppLockPlatform.sentinelState() != SentinelState.valid) {
          await disable();
          return BiometricUnlockOutcome.enrollmentChanged;
        }
      }

      switch (await AppLockPlatform.biometricStatus()) {
        case BiometricAvailability.available:
          break;
        // Nothing is enrolled any more, or the phone lock is gone: there is
        // nothing left this setting could ever accept.
        case BiometricAvailability.noneEnrolled:
        case BiometricAvailability.noDeviceLock:
          await disable();
          return BiometricUnlockOutcome.enrollmentChanged;
        case BiometricAvailability.unavailable:
        case BiometricAvailability.unsupported:
          return BiometricUnlockOutcome.unavailable;
      }

      // The system prompt can pause the activity on some builds; a pause the
      // app started itself must not trip «قفل خودکار» or close the secure
      // section (see AppHandoff).
      final result = await AppHandoff.run(
        () => AppLockPlatform.authenticate(
          title: _unlockTitle,
          subtitle: _subtitle,
          negative: _negative,
        ),
      );
      switch (result) {
        case BiometricPromptResult.success:
          return BiometricUnlockOutcome.unlocked;
        case BiometricPromptResult.cancelled:
        case BiometricPromptResult.busy:
          return BiometricUnlockOutcome.cancelled;
        case BiometricPromptResult.lockout:
        case BiometricPromptResult.lockoutPermanent:
          return BiometricUnlockOutcome.lockedOut;
        case BiometricPromptResult.noneEnrolled:
          await disable();
          return BiometricUnlockOutcome.enrollmentChanged;
        case BiometricPromptResult.unavailable:
          return BiometricUnlockOutcome.unavailable;
        case BiometricPromptResult.error:
          return BiometricUnlockOutcome.failed;
      }
    } catch (_) {
      return BiometricUnlockOutcome.failed;
    }
  }

  /// Turns the setting on — after the user proves the biometric works with a
  /// real prompt, so it is never switched on for a finger the phone does not
  /// know. Never throws.
  Future<BiometricEnableOutcome> enable() async {
    try {
      if (await _auth.getAuthType() != AuthType.pin) {
        return BiometricEnableOutcome.failed;
      }
      switch (await AppLockPlatform.biometricStatus()) {
        case BiometricAvailability.available:
          break;
        case BiometricAvailability.noneEnrolled:
          return BiometricEnableOutcome.noneEnrolled;
        case BiometricAvailability.noDeviceLock:
          return BiometricEnableOutcome.noDeviceLock;
        case BiometricAvailability.unavailable:
          return BiometricEnableOutcome.failed;
        case BiometricAvailability.unsupported:
          return BiometricEnableOutcome.unsupported;
      }
      final result = await AppHandoff.run(
        () => AppLockPlatform.authenticate(
          title: 'فعال کردن اثر انگشت یا چهره',
          subtitle: _subtitle,
          negative: 'انصراف',
        ),
      );
      switch (result) {
        case BiometricPromptResult.success:
          break;
        case BiometricPromptResult.cancelled:
        case BiometricPromptResult.busy:
          return BiometricEnableOutcome.cancelled;
        case BiometricPromptResult.noneEnrolled:
          return BiometricEnableOutcome.noneEnrolled;
        default:
          return BiometricEnableOutcome.failed;
      }
      final sentinel = await AppLockPlatform.createSentinel();
      await _storage.write(
        key: AppConstants.biometricSentinelKey,
        value: sentinel.toString(),
      );
      await _storage.write(key: AppConstants.biometricUnlockKey, value: 'true');
      return BiometricEnableOutcome.enabled;
    } catch (_) {
      return BiometricEnableOutcome.failed;
    }
  }

  /// Turns the setting off and forgets the sentinel.
  Future<void> disable() async {
    await _storage.delete(key: AppConstants.biometricUnlockKey);
    await _storage.delete(key: AppConstants.biometricSentinelKey);
    await AppLockPlatform.deleteSentinel();
  }

  /// What to tell the user for an [outcome] on a lock screen; null when the
  /// screen should just stay as it is.
  static String? messageFor(
    BiometricUnlockOutcome outcome,
  ) => switch (outcome) {
    BiometricUnlockOutcome.enrollmentChanged =>
      'اثر انگشت یا چهرهٔ گوشی تغییر کرده است؛ برای امنیت، باز کردن با آن '
          'خاموش شد. با رمز وارد شوید و در صورت نیاز دوباره از تنظیمات روشنش کنید',
    BiometricUnlockOutcome.lockedOut =>
      'تلاش‌های زیادی انجام شد؛ فعلاً با رمز وارد شوید',
    BiometricUnlockOutcome.failed =>
      'اثر انگشت یا چهره در دسترس نیست؛ با رمز وارد شوید',
    _ => null,
  };
}
