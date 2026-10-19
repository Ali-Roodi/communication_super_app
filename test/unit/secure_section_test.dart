import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/models/pin_policy.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/repositories/pin_attempt_limiter.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';
import 'package:communication_super_app/features/secure/services/secure_vault_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAuth extends Mock implements AuthRepository {}

class _MockEditionBloc extends MockBloc<EditionEvent, EditionState>
    implements EditionBloc {}

/// Records what the session bloc asks of the store; behaves like one — a
/// vault sealed under [vaultPin] (null: no vault) and a biometric copy.
class _FakeStore implements SecureStore {
  String? vaultPin;
  bool open = false;
  bool windowSecure = false;
  bool bio = false;
  BiometricAvailability availability = BiometricAvailability.available;
  final List<String> calls = [];

  /// Thrown by [unlock] / [create] / [rekey] when set.
  Object? failWith;

  /// Thrown by [unlockWithBiometric] when set.
  Object? bioFailWith;

  bool get _vaultExists => vaultPin != null;

  static const _wrong = SecureStoreException(VaultFailure.wrongPin);

  @override
  bool get isOpen => open;

  @override
  Future<bool> exists() async => _vaultExists;

  @override
  Future<void> create(String pin) async {
    calls.add('create:$pin');
    if (failWith != null) throw failWith!;
    vaultPin = pin;
    bio = false;
    open = true;
  }

  @override
  Future<void> unlock(String pin) async {
    calls.add('unlock:$pin');
    if (failWith != null) throw failWith!;
    if (pin != vaultPin) throw _wrong;
    open = true;
  }

  @override
  Future<void> verifyPin(String pin) async {
    calls.add('verify:$pin');
    if (pin != vaultPin) throw _wrong;
  }

  @override
  Future<void> unlockWithBiometric() async {
    calls.add('bioUnlock');
    final failure = bioFailWith;
    if (failure != null) {
      if (failure is SecureStoreException &&
          failure.failure == VaultFailure.bioInvalidated) {
        bio = false;
      }
      throw failure;
    }
    if (!bio) throw const SecureStoreException(VaultFailure.bioOff);
    open = true;
  }

  @override
  Future<BiometricAvailability> biometricStatus() async => availability;

  @override
  Future<bool> biometricEnabled() async => _vaultExists && bio;

  @override
  Future<void> enableBiometric(String pin) async {
    calls.add('bioEnable:$pin');
    if (pin != vaultPin) throw _wrong;
    bio = true;
  }

  @override
  Future<void> disableBiometric() async {
    calls.add('bioDisable');
    bio = false;
  }

  @override
  Future<void> lock() async {
    calls.add('lock');
    open = false;
  }

  @override
  Future<void> rekey(String oldPin, String newPin) async {
    calls.add('rekey:$oldPin>$newPin');
    if (failWith != null) throw failWith!;
    if (oldPin != vaultPin) throw _wrong;
    vaultPin = newPin;
  }

  @override
  Future<void> reset() async {
    calls.add('reset');
    open = false;
    vaultPin = null;
    bio = false;
  }

  @override
  Future<void> setSecureWindow(bool secure) async {
    calls.add('window:$secure');
    windowSecure = secure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

EditionState _edition(AppEdition e) => EditionState(edition: e, loaded: true);

void main() {
  group('PinAttemptLimiter', () {
    late DateTime now;
    late PinAttemptLimiter limiter;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = DateTime(2026, 9, 27, 12);
      limiter = PinAttemptLimiter(now: () => now);
    });

    test('five free attempts, then a 30-second lockout', () async {
      for (var i = 0; i < 4; i++) {
        await limiter.recordFailure();
        expect(await limiter.retryAfter(), isNull, reason: 'failure ${i + 1}');
      }
      await limiter.recordFailure(); // the 5th
      expect(await limiter.retryAfter(), const Duration(seconds: 30));
      now = now.add(const Duration(seconds: 30));
      expect(await limiter.retryAfter(), isNull);
    });

    test('each further failure doubles the lockout, capped at 30 min', () {
      expect(PinAttemptLimiter.lockoutAfter(4), Duration.zero);
      expect(PinAttemptLimiter.lockoutAfter(5), const Duration(seconds: 30));
      expect(PinAttemptLimiter.lockoutAfter(6), const Duration(minutes: 1));
      expect(PinAttemptLimiter.lockoutAfter(7), const Duration(minutes: 2));
      expect(PinAttemptLimiter.lockoutAfter(11), const Duration(minutes: 30));
      expect(PinAttemptLimiter.lockoutAfter(500), const Duration(minutes: 30));
    });

    test('a success clears the count', () async {
      for (var i = 0; i < 5; i++) {
        await limiter.recordFailure();
      }
      await limiter.recordSuccess();
      await limiter.recordFailure();
      expect(await limiter.retryAfter(), isNull);
    });

    test(
      'a clock set backwards cannot stretch a lockout past the cap',
      () async {
        for (var i = 0; i < 5; i++) {
          await limiter.recordFailure();
        }
        now = now.subtract(const Duration(days: 365));
        expect(await limiter.retryAfter(), PinAttemptLimiter.maxLockout);
      },
    );

    test('the lockout message names the wait in Persian', () {
      expect(
        PinAttemptLimiter.lockoutMessage(const Duration(seconds: 30)),
        contains('۳۰ ثانیه'),
      );
      expect(
        PinAttemptLimiter.lockoutMessage(const Duration(seconds: 90)),
        contains('۲ دقیقه'),
      );
    });
  });

  test(
    'PinPolicy: 4 digits commercial, 6 wherever there is a secure section',
    () {
      expect(PinPolicy.requiredFor(AppEdition.commercial), 4);
      expect(PinPolicy.requiredFor(AppEdition.interOrganization), 6);
      expect(PinPolicy.requiredFor(AppEdition.organization), 6);
    },
  );

  group('SecureSessionBloc', () {
    late _MockAuth auth;
    late _MockEditionBloc edition;
    late _FakeStore store;
    late DateTime now;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = DateTime(2026, 10, 19, 12);
      auth = _MockAuth();
      edition = _MockEditionBloc();
      store = _FakeStore();
      when(
        () => edition.state,
      ).thenReturn(_edition(AppEdition.interOrganization));
      whenListen(edition, const Stream<EditionState>.empty());
      // The app PIN is 111111; the section's is never allowed to be that.
      when(() => auth.isAppPin(any())).thenAnswer((i) async {
        return i.positionalArguments.first == '111111';
      });
    });

    SecureSessionBloc build() => SecureSessionBloc(
      edition: edition,
      store: store,
      auth: auth,
      limiter: PinAttemptLimiter.secureSection(now: () => now),
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'the commercial edition has no section',
      setUp: () =>
          when(() => edition.state).thenReturn(_edition(AppEdition.commercial)),
      build: build,
      act: (b) => b.add(const SecureSessionRefresh()),
      // A bloc's first emit goes through even when equal to the initial state.
      expect: () => [const SecureSessionState()],
      verify: (b) {
        expect(b.state.status, SecureStatus.unavailable);
        expect(store.calls, isEmpty);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'no section yet: notCreated — whatever the app PIN is, or if there is none',
      build: build,
      act: (b) => b.add(const SecureSessionRefresh()),
      verify: (b) {
        expect(b.state.status, SecureStatus.notCreated);
        verifyNever(() => auth.getAuthType());
        verifyNever(() => auth.validatePin(any()));
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'creating sets the section PIN; the window is secured first',
      build: build,
      act: (b) => b.add(const SecureCreateRequested('246810')),
      verify: (b) {
        expect(b.state.status, SecureStatus.unlocked);
        expect(store.calls.take(2), ['window:true', 'create:246810']);
        expect(store.vaultPin, '246810');
        expect(store.windowSecure, isTrue);
        // The app PIN is never asked for or checked as an unlock.
        verifyNever(() => auth.validatePin(any()));
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'the app PIN is refused as the section PIN',
      build: build,
      act: (b) => b.add(const SecureCreateRequested('111111')),
      verify: (b) {
        expect(b.state.status, SecureStatus.notCreated);
        expect(b.state.failureMessage, contains('رمز برنامه'));
        expect(store.calls, isEmpty);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'a PIN that is not 6 digits never creates anything',
      build: build,
      act: (b) => b.add(const SecureCreateRequested('1234')),
      verify: (_) => expect(store.calls, isEmpty),
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'the section PIN opens it; the app lock has nothing to do with it',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('246810')),
      verify: (b) {
        expect(b.state.status, SecureStatus.unlocked);
        expect(store.calls.take(2), ['window:true', 'unlock:246810']);
        verifyNever(() => auth.validatePin(any()));
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'the app PIN does not open the section',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('111111')),
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(b.state.lastFailure, SecureFailure.wrongPin);
        expect(b.state.failureMessage, 'رمز بخش امن اشتباه است');
        expect(store.windowSecure, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'five wrong section PINs lock it out — and then even the right one is '
      'not tried',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        for (var i = 0; i < 5; i++) {
          b.add(const SecureUnlockRequested('000000'));
          await Future<void>.delayed(Duration.zero);
        }
        store.calls.clear();
        b.add(const SecureUnlockRequested('246810'));
      },
      verify: (b) {
        expect(b.state.lastFailure, SecureFailure.lockedOut);
        expect(b.state.failureMessage, contains('۳۰ ثانیه'));
        expect(store.calls.where((c) => c.startsWith('unlock')), isEmpty);
      },
    );

    test('the section budget and the app budget are separate', () async {
      SharedPreferences.setMockInitialValues({});
      final app = PinAttemptLimiter(now: () => now);
      final section = PinAttemptLimiter.secureSection(now: () => now);
      for (var i = 0; i < 5; i++) {
        await section.recordFailure();
      }
      expect(await section.retryAfter(), isNotNull);
      expect(await app.retryAfter(), isNull);
      await app.recordSuccess();
      expect(await section.retryAfter(), isNotNull);
    });

    blocTest<SecureSessionBloc, SecureSessionState>(
      'a damaged vault is broken, and the window is released',
      setUp: () {
        store.vaultPin = '246810';
        store.failWith = const SecureStoreException(VaultFailure.corrupt);
      },
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('246810')),
      verify: (b) {
        expect(b.state.status, SecureStatus.broken);
        expect(b.state.busy, isFalse);
        expect(store.windowSecure, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'an unforeseen error never leaves the screen busy or the window secure',
      setUp: () {
        store.vaultPin = '246810';
        store.failWith = StateError('disk full');
      },
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('246810')),
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(b.state.busy, isFalse);
        expect(b.state.lastFailure, SecureFailure.failed);
        expect(store.open, isFalse);
        expect(store.windowSecure, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'the fingerprint opens it when it is on',
      setUp: () {
        store.vaultPin = '246810';
        store.bio = true;
      },
      build: build,
      act: (b) async {
        b.add(const SecureSessionRefresh());
        await Future<void>.delayed(Duration.zero);
        final done = Completer<SecureBiometricOutcome>();
        b.add(SecureBiometricUnlockRequested(done: done));
        expect(await done.future, SecureBiometricOutcome.unlocked);
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.unlocked);
        expect(store.calls, containsAllInOrder(['window:true', 'bioUnlock']));
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'a dismissed fingerprint prompt leaves it locked and says nothing',
      setUp: () {
        store.vaultPin = '246810';
        store.bio = true;
        store.bioFailWith = const SecureStoreException(
          VaultFailure.bioCancelled,
        );
      },
      build: build,
      act: (b) async {
        b.add(const SecureSessionRefresh());
        await Future<void>.delayed(Duration.zero);
        final done = Completer<SecureBiometricOutcome>();
        b.add(SecureBiometricUnlockRequested(done: done));
        expect(await done.future, SecureBiometricOutcome.cancelled);
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(b.state.failureMessage, isNull);
        expect(store.windowSecure, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'a finger enrolled since turns the fingerprint off, and says so',
      setUp: () {
        store.vaultPin = '246810';
        store.bio = true;
        store.bioFailWith = const SecureStoreException(
          VaultFailure.bioInvalidated,
        );
      },
      build: build,
      act: (b) async {
        b.add(const SecureSessionRefresh());
        await Future<void>.delayed(Duration.zero);
        final done = Completer<SecureBiometricOutcome>();
        b.add(SecureBiometricUnlockRequested(done: done));
        expect(await done.future, SecureBiometricOutcome.invalidated);
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(b.state.biometricOn, isFalse);
        expect(b.state.failureMessage, contains('اثر انگشت'));
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'the fingerprint is not tried while it is off',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureSessionRefresh());
        await Future<void>.delayed(Duration.zero);
        final done = Completer<SecureBiometricOutcome>();
        b.add(SecureBiometricUnlockRequested(done: done));
        expect(await done.future, SecureBiometricOutcome.unavailable);
      },
      verify: (_) => expect(store.calls, isNot(contains('bioUnlock'))),
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'turning the fingerprint on takes the section PIN',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureSessionRefresh());
        await Future<void>.delayed(Duration.zero);
        final wrong = Completer<String?>();
        b.add(SecureBiometricToggleRequested(true, wrong, pin: '000000'));
        expect(await wrong.future, 'رمز بخش امن اشتباه است');
        final right = Completer<String?>();
        b.add(SecureBiometricToggleRequested(true, right, pin: '246810'));
        expect(await right.future, isNull);
      },
      verify: (b) {
        expect(b.state.biometricOn, isTrue);
        expect(store.calls, contains('bioEnable:246810'));
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'turning it off needs nothing',
      setUp: () {
        store.vaultPin = '246810';
        store.bio = true;
      },
      build: build,
      act: (b) async {
        final done = Completer<String?>();
        b.add(SecureBiometricToggleRequested(false, done));
        expect(await done.future, isNull);
      },
      verify: (b) {
        expect(b.state.biometricOn, isFalse);
        expect(store.bio, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'changing the section PIN: the old one stops working, the new one opens',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureSessionRefresh());
        await Future<void>.delayed(Duration.zero);
        final done = Completer<String?>();
        b.add(SecureChangePinRequested('246810', '135790', done));
        expect(await done.future, isNull);
        b.add(const SecureUnlockRequested('246810'));
        await Future<void>.delayed(Duration.zero);
        expect(b.state.lastFailure, SecureFailure.wrongPin);
        b.add(const SecureUnlockRequested('135790'));
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.unlocked);
        expect(store.vaultPin, '135790');
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'a wrong current PIN changes nothing; the app PIN is refused as the new',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureSessionRefresh());
        await Future<void>.delayed(Duration.zero);
        final wrong = Completer<String?>();
        b.add(SecureChangePinRequested('000000', '135790', wrong));
        expect(await wrong.future, contains('اشتباه'));
        final appPin = Completer<String?>();
        b.add(SecureChangePinRequested('246810', '111111', appPin));
        expect(await appPin.future, contains('رمز برنامه'));
      },
      verify: (_) => expect(store.vaultPin, '246810'),
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'checking the PIN opens nothing',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureSessionRefresh());
        await Future<void>.delayed(Duration.zero);
        final right = Completer<String?>();
        b.add(SecureVerifyPinRequested('246810', right));
        expect(await right.future, isNull);
        final wrong = Completer<String?>();
        b.add(SecureVerifyPinRequested('000000', wrong));
        expect(await wrong.future, 'رمز بخش امن اشتباه است');
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(store.open, isFalse);
        expect(store.windowSecure, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'the lock icon closes the section and releases the window at once',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureUnlockRequested('246810'));
        await Future<void>.delayed(Duration.zero);
        b.add(const SecureLockRequested());
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(store.calls.skip(2).take(2), ['lock', 'window:false']);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'leaving the app locks at once but keeps the window secure until resume',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureUnlockRequested('246810'));
        await Future<void>.delayed(Duration.zero);
        b.add(const SecureAppBackgrounded());
        await Future<void>.delayed(Duration.zero);
        expect(store.open, isFalse);
        expect(store.windowSecure, isTrue); // the recents thumbnail
        b.add(const SecureAppResumed());
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(store.windowSecure, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'a forgotten section PIN: reset deletes it; a new one can be created',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureResetRequested());
        await Future<void>.delayed(Duration.zero);
        b.add(const SecureCreateRequested('975310'));
      },
      verify: (b) {
        expect(store.calls, containsAllInOrder(['reset', 'create:975310']));
        expect(b.state.status, SecureStatus.unlocked);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'reset clears a broken section',
      setUp: () {
        store.vaultPin = '246810';
        store.failWith = const SecureStoreException(VaultFailure.keyLost);
      },
      build: build,
      act: (b) async {
        b.add(const SecureUnlockRequested('246810'));
        await Future<void>.delayed(Duration.zero);
        expect(b.state.status, SecureStatus.broken);
        store.failWith = null;
        b.add(const SecureResetRequested());
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.notCreated);
        expect(b.state.failureMessage, isNull);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'losing the secure edition while open closes the section',
      setUp: () => store.vaultPin = '246810',
      build: build,
      act: (b) async {
        b.add(const SecureUnlockRequested('246810'));
        await Future<void>.delayed(Duration.zero);
        when(() => edition.state).thenReturn(_edition(AppEdition.commercial));
        b.add(const SecureSessionRefresh());
      },
      verify: (b) {
        expect(b.state.status, SecureStatus.unavailable);
        expect(store.open, isFalse);
        expect(store.windowSecure, isFalse);
      },
    );
  });

  group('the app PIN never touches the secure section', () {
    late _MockAuth repo;

    setUp(() {
      repo = _MockAuth();
      when(() => repo.setPin(any())).thenAnswer((_) async {});
      when(() => repo.setAuthSkipped(any())).thenAnswer((_) async {});
      when(() => repo.setAuthenticated(any())).thenAnswer((_) async {});
      when(() => repo.clearAuth()).thenAnswer((_) async {});
      when(
        () => repo.regenerateRecoveryCode(),
      ).thenAnswer((_) async => 'ABCD-EFGH-JKLM');
    });

    blocTest<AuthBloc, AuthState>(
      'the app PIN can be removed while a section exists',
      build: () => AuthBloc(repo),
      act: (b) => b.add(const DisableAuth()),
      expect: () => [const AuthLoading(), const AuthAuthenticated()],
      verify: (_) => verify(() => repo.clearAuth()).called(1),
    );

    blocTest<AuthBloc, AuthState>(
      'recovering a forgotten app PIN only resets the app PIN',
      setUp: () => when(
        () => repo.validateRecoveryCode(any()),
      ).thenAnswer((_) async => true),
      build: () => AuthBloc(repo),
      act: (b) => b.add(const RecoverWithCode('ABCD-EFGH-JKLM')),
      expect: () => [const AuthLoading(), const AuthNotSet()],
    );

    blocTest<AuthBloc, AuthState>(
      'setting a new app PIN just sets it',
      build: () => AuthBloc(repo),
      act: (b) => b.add(const SetPin('5678')),
      verify: (_) => verify(() => repo.setPin('5678')).called(1),
    );
  });
}
