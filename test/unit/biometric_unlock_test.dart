import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/services/biometric_unlock.dart';
import 'package:communication_super_app/features/authentication/services/notification_privacy_sync.dart';

/// «باز کردن با اثر انگشت یا چهره» and «پنهان کردن محتوای اعلان‌ها», against a
/// scripted `…/app_lock` channel and an in-memory secure storage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const lockChannel = MethodChannel(
    'com.example.communication_super_app/app_lock',
  );

  final store = <String, String>{};

  // What the phone answers.
  late String status;
  late String prompt;
  late String sentinel;
  late bool sentinelCreatable;
  late List<MethodCall> lockCalls;

  setUp(() {
    store.clear();
    status = 'available';
    prompt = 'success';
    sentinel = 'valid';
    sentinelCreatable = true;
    lockCalls = [];
    AuthRepository.resetSessionForTest();
    SharedPreferences.setMockInitialValues({});

    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          store[key!] = args['value'] as String;
          return null;
        case 'read':
          return store[key];
        case 'delete':
          store.remove(key);
          return null;
        case 'containsKey':
          return store.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(store);
        case 'deleteAll':
          store.clear();
          return null;
      }
      return null;
    });

    messenger.setMockMethodCallHandler(lockChannel, (call) async {
      lockCalls.add(call);
      switch (call.method) {
        case 'biometricStatus':
          return status;
        case 'authenticate':
          return prompt;
        case 'sentinelState':
          return sentinel;
        case 'createSentinel':
          return sentinelCreatable;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(storageChannel, null);
    messenger.setMockMethodCallHandler(lockChannel, null);
  });

  Future<void> withPin() => AuthRepository().setPin('123456');

  bool called(String method) => lockCalls.any((c) => c.method == method);

  group('enable', () {
    test('needs a PIN: there is nothing for it to stand in for', () async {
      final outcome = await BiometricUnlock().enable();
      expect(outcome, BiometricEnableOutcome.failed);
      expect(called('authenticate'), isFalse);
      expect(store.containsKey(AppConstants.biometricUnlockKey), isFalse);
    });

    test('turns on only after a real prompt succeeds', () async {
      await withPin();
      final outcome = await BiometricUnlock().enable();
      expect(outcome, BiometricEnableOutcome.enabled);
      expect(called('authenticate'), isTrue);
      expect(store[AppConstants.biometricUnlockKey], 'true');
      expect(store[AppConstants.biometricSentinelKey], 'true');
      expect(await BiometricUnlock().isEnabled(), isTrue);
    });

    test('a dismissed prompt leaves it off', () async {
      await withPin();
      prompt = 'cancelled';
      expect(await BiometricUnlock().enable(), BiometricEnableOutcome.cancelled);
      expect(await BiometricUnlock().isEnabled(), isFalse);
      expect(called('createSentinel'), isFalse);
    });

    test('nothing enrolled on the phone: says so, never prompts', () async {
      await withPin();
      status = 'none_enrolled';
      expect(
        await BiometricUnlock().enable(),
        BiometricEnableOutcome.noneEnrolled,
      );
      expect(called('authenticate'), isFalse);
    });

    test('a weak-only biometric is enabled without a sentinel', () async {
      await withPin();
      sentinelCreatable = false;
      expect(await BiometricUnlock().enable(), BiometricEnableOutcome.enabled);
      expect(store[AppConstants.biometricSentinelKey], 'false');
    });
  });

  group('unlock', () {
    Future<void> enabled() async {
      await withPin();
      await BiometricUnlock().enable();
      lockCalls.clear();
    }

    test('off: never shows a prompt', () async {
      await withPin();
      expect(
        await BiometricUnlock().unlock(),
        BiometricUnlockOutcome.notEnabled,
      );
      expect(called('authenticate'), isFalse);
    });

    test('a matching finger unlocks', () async {
      await enabled();
      expect(await BiometricUnlock().unlock(), BiometricUnlockOutcome.unlocked);
    });

    test('a fingerprint added since switches it off, before any prompt',
        () async {
      await enabled();
      sentinel = 'invalidated';
      expect(
        await BiometricUnlock().unlock(),
        BiometricUnlockOutcome.enrollmentChanged,
      );
      expect(called('authenticate'), isFalse);
      expect(called('deleteSentinel'), isTrue);
      expect(await BiometricUnlock().isEnabled(), isFalse);
    });

    test('a sentinel the system deleted counts as changed too', () async {
      await enabled();
      sentinel = 'absent';
      expect(
        await BiometricUnlock().unlock(),
        BiometricUnlockOutcome.enrollmentChanged,
      );
      expect(await BiometricUnlock().isEnabled(), isFalse);
    });

    test('without a sentinel (weak biometric) the check is skipped', () async {
      await withPin();
      sentinelCreatable = false;
      await BiometricUnlock().enable();
      sentinel = 'absent';
      expect(await BiometricUnlock().unlock(), BiometricUnlockOutcome.unlocked);
    });

    test('every biometric removed from the phone switches it off', () async {
      await enabled();
      status = 'none_enrolled';
      expect(
        await BiometricUnlock().unlock(),
        BiometricUnlockOutcome.enrollmentChanged,
      );
      expect(await BiometricUnlock().isEnabled(), isFalse);
    });

    test('a sensor that is busy right now keeps the setting', () async {
      await enabled();
      status = 'unavailable';
      expect(
        await BiometricUnlock().unlock(),
        BiometricUnlockOutcome.unavailable,
      );
      expect(await BiometricUnlock().isEnabled(), isTrue);
    });

    test('lockout and cancel leave the PIN as the way in', () async {
      await enabled();
      prompt = 'lockout';
      expect(await BiometricUnlock().unlock(), BiometricUnlockOutcome.lockedOut);
      prompt = 'cancelled';
      expect(await BiometricUnlock().unlock(), BiometricUnlockOutcome.cancelled);
      expect(await BiometricUnlock().isEnabled(), isTrue);
    });

    test('a channel failure is a failure, never an unlock', () async {
      await enabled();
      messenger.setMockMethodCallHandler(lockChannel, (call) async {
        if (call.method == 'authenticate') {
          throw PlatformException(code: 'boom');
        }
        if (call.method == 'biometricStatus') return 'available';
        if (call.method == 'sentinelState') return 'valid';
        return null;
      });
      expect(await BiometricUnlock().unlock(), BiometricUnlockOutcome.failed);
    });
  });

  test('removing the PIN removes biometric unlock with it', () async {
    await withPin();
    await BiometricUnlock().enable();
    await AuthRepository().clearAuth();
    expect(store.containsKey(AppConstants.biometricUnlockKey), isFalse);
    expect(store.containsKey(AppConstants.biometricSentinelKey), isFalse);
    expect(called('deleteSentinel'), isTrue);
    // A PIN set again later does not inherit it.
    await withPin();
    expect(await BiometricUnlock().isEnabled(), isFalse);
  });

  group('AuthBloc', () {
    blocTest<AuthBloc, AuthState>(
      'BiometricUnlocked opens the app when the setting is on',
      setUp: () async {
        await withPin();
        await BiometricUnlock().enable();
      },
      build: () => AuthBloc(AuthRepository()),
      act: (bloc) => bloc.add(const BiometricUnlocked()),
      expect: () => [const AuthAuthenticated()],
      verify: (_) async {
        expect(await AuthRepository().isAuthenticated(), isTrue);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'BiometricUnlocked is ignored when the setting is off',
      setUp: withPin,
      build: () => AuthBloc(AuthRepository()),
      act: (bloc) => bloc.add(const BiometricUnlocked()),
      expect: () => <AuthState>[],
      verify: (_) async {
        expect(await AuthRepository().isAuthenticated(), isFalse);
      },
    );
  });

  group('NotificationPrivacySync', () {
    bool? pushed() {
      final writes = lockCalls.where(
        (c) => c.method == 'setHideNotificationContent',
      );
      return writes.isEmpty
          ? null
          : (writes.last.arguments as Map)['value'] as bool;
    }

    test('no PIN: notifications show their content', () async {
      await NotificationPrivacySync.sync();
      expect(pushed(), isFalse);
    });

    test('a PIN hides it by default', () async {
      await withPin();
      await NotificationPrivacySync.sync();
      expect(pushed(), isTrue);
    });

    test('the switch turned off shows it even with a PIN', () async {
      await withPin();
      SharedPreferences.setMockInitialValues({
        'set_hideNotificationContent': false,
      });
      await NotificationPrivacySync.sync();
      expect(pushed(), isFalse);
    });
  });
}
