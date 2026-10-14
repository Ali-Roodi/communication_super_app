import 'package:flutter/foundation.dart';

import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import '../models/auth_type.dart';
import '../repositories/auth_repository.dart';
import 'app_lock_platform.dart';

/// Keeps the native «پنهان کردن محتوای اعلان‌ها» flag (`NotificationPrivacy`)
/// equal to `an app PIN is set && the switch is on`.
///
/// The SMS and missed-call cards are posted natively, usually with no engine,
/// so the native side cannot ask either question when it matters. This runs
/// on every settings load (each launch), when the switch changes, and after
/// every change to the PIN (`AuthBloc`), so the mirror is never more than one
/// event behind.
abstract final class NotificationPrivacySync {
  static Future<void> sync() async {
    try {
      final hasPin = await AuthRepository().getAuthType() == AuthType.pin;
      final wanted = await SettingsBloc.readHideNotificationContent();
      await AppLockPlatform.setHideNotificationContent(hasPin && wanted);
    } catch (e) {
      debugPrint('NotificationPrivacySync failed: $e');
    }
  }
}
