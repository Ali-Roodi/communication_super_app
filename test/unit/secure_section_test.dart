import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
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

/// Records what the session bloc asks of the store; behaves like one.
class _FakeStore implements SecureStore {
  bool vaultExists = false;
  bool open = false;
  bool windowSecure = false;
  final List<String> calls = [];

  /// Thrown by [unlock] / [create] when set.
  Object? failWith;

  @override
  bool get isOpen => open;

  @override
  Future<bool> exists() async => vaultExists;

  @override
  Future<void> create(String pin) async {
    calls.add('create:$pin');
    if (failWith != null) throw failWith!;
    vaultExists = true;
    open = true;
  }

  @override
  Future<void> unlock(String pin) async {
    calls.add('unlock:$pin');
    if (failWith != null) throw failWith!;
    open = true;
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
  }

  @override
  Future<void> reset() async {
    calls.add('reset');
    open = false;
    vaultExists = false;
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

    setUp(() {
      auth = _MockAuth();
      edition = _MockEditionBloc();
      store = _FakeStore();
      when(
        () => edition.state,
      ).thenReturn(_edition(AppEdition.interOrganization));
      whenListen(edition, const Stream<EditionState>.empty());
      when(() => auth.getAuthType()).thenAnswer((_) async => AuthType.pin);
      when(() => auth.validatePin('1234')).thenAnswer((_) async => true);
      when(() => auth.validatePin('9999')).thenAnswer((_) async => false);
      when(() => auth.pinRetryAfter()).thenAnswer((_) async => null);
      when(() => auth.pinLength()).thenAnswer((_) async => 6);
    });

    SecureSessionBloc build() =>
        SecureSessionBloc(edition: edition, store: store, auth: auth);

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
      'no app PIN: the section asks for one',
      setUp: () =>
          when(() => auth.getAuthType()).thenAnswer((_) async => AuthType.none),
      build: build,
      act: (b) => b.add(const SecureSessionRefresh()),
      expect: () => [const SecureSessionState(status: SecureStatus.needsPin)],
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'a 4-digit PIN cannot create a section — it must become 6 digits',
      setUp: () => when(() => auth.pinLength()).thenAnswer((_) async => 4),
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('1234')),
      verify: (b) {
        expect(b.state.status, SecureStatus.pinTooShort);
        expect(store.calls, isEmpty);
        verifyNever(() => auth.validatePin(any()));
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'an existing section is never locked out by a short PIN',
      setUp: () {
        store.vaultExists = true;
        when(() => auth.pinLength()).thenAnswer((_) async => 4);
      },
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('1234')),
      verify: (b) =>
          expect(store.calls.take(2), ['window:true', 'unlock:1234']),
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'first unlock creates the section; the window is secured first',
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('1234')),
      verify: (b) {
        expect(b.state.status, SecureStatus.unlocked);
        expect(store.calls.take(2), ['window:true', 'create:1234']);
        expect(store.windowSecure, isTrue);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'a wrong PIN never reaches the vault',
      setUp: () => store.vaultExists = true,
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('9999')),
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(b.state.lastFailure, SecureFailure.wrongPin);
        expect(b.state.failureMessage, 'رمز عبور اشتباه است');
        // Nothing was opened, so nothing (bar close's no-op lock) ran.
        expect(store.calls.where((c) => c != 'lock'), isEmpty);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'while locked out, the lockout is what the user is told',
      setUp: () {
        store.vaultExists = true;
        when(
          () => auth.pinRetryAfter(),
        ).thenAnswer((_) async => const Duration(seconds: 30));
      },
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('9999')),
      verify: (b) {
        expect(b.state.lastFailure, SecureFailure.lockedOut);
        expect(b.state.failureMessage, contains('۳۰ ثانیه'));
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'right app PIN, vault refuses it: broken, and the window is released',
      setUp: () {
        store.vaultExists = true;
        store.failWith = const SecureStoreException(VaultFailure.wrongPin);
      },
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('1234')),
      verify: (b) {
        expect(b.state.status, SecureStatus.broken);
        expect(b.state.busy, isFalse);
        expect(store.windowSecure, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'an unforeseen error never leaves the screen busy or the window secure',
      setUp: () {
        store.vaultExists = true;
        store.failWith = StateError('disk full');
      },
      build: build,
      act: (b) => b.add(const SecureUnlockRequested('1234')),
      verify: (b) {
        expect(b.state.status, SecureStatus.locked);
        expect(b.state.busy, isFalse);
        expect(b.state.lastFailure, SecureFailure.failed);
        expect(store.open, isFalse);
        expect(store.windowSecure, isFalse);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'the lock icon closes the section and releases the window at once',
      setUp: () => store.vaultExists = true,
      build: build,
      act: (b) async {
        b.add(const SecureUnlockRequested('1234'));
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
      setUp: () => store.vaultExists = true,
      build: build,
      act: (b) async {
        b.add(const SecureUnlockRequested('1234'));
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
      'reset deletes the section; it can then be created afresh',
      setUp: () => store.vaultExists = true,
      build: build,
      act: (b) => b.add(const SecureResetRequested()),
      verify: (b) {
        expect(store.calls, contains('reset'));
        expect(b.state.status, SecureStatus.notCreated);
      },
    );

    blocTest<SecureSessionBloc, SecureSessionState>(
      'losing the secure edition while open closes the section',
      setUp: () => store.vaultExists = true,
      build: build,
      act: (b) async {
        b.add(const SecureUnlockRequested('1234'));
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

  group('AuthBloc keeps the secure section in step with the app PIN', () {
    late _MockAuth repo;
    late _FakeStore store;

    setUp(() {
      repo = _MockAuth();
      store = _FakeStore()..vaultExists = true;
      when(() => repo.validatePin('1234')).thenAnswer((_) async => true);
      when(() => repo.validatePin('9999')).thenAnswer((_) async => false);
      when(() => repo.setPin(any())).thenAnswer((_) async {});
      when(() => repo.setAuthSkipped(any())).thenAnswer((_) async {});
      when(() => repo.setAuthenticated(any())).thenAnswer((_) async {});
      when(
        () => repo.regenerateRecoveryCode(),
      ).thenAnswer((_) async => 'ABCD-EFGH-JKLM');
    });

    AuthBloc build() => AuthBloc(repo, secureStore: store);

    blocTest<AuthBloc, AuthState>(
      'changing the PIN re-seals the section first',
      build: build,
      act: (b) => b.add(const SetPin('5678', currentPin: '1234')),
      verify: (_) {
        expect(store.calls, ['rekey:1234>5678']);
        verify(() => repo.setPin('5678')).called(1);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'a wrong current PIN changes nothing',
      build: build,
      act: (b) => b.add(const SetPin('5678', currentPin: '9999')),
      expect: () => [
        const AuthLoading(),
        const AuthValidationFailure('رمز فعلی نادرست است'),
      ],
      verify: (_) {
        expect(store.calls, isEmpty);
        verifyNever(() => repo.setPin(any()));
      },
    );

    blocTest<AuthBloc, AuthState>(
      'no current PIN while a section exists changes nothing',
      build: build,
      act: (b) => b.add(const SetPin('5678')),
      verify: (_) {
        expect(store.calls, isEmpty);
        verifyNever(() => repo.setPin(any()));
      },
    );

    blocTest<AuthBloc, AuthState>(
      'a PIN that fails to save is sealed back to the old one',
      setUp: () =>
          when(() => repo.setPin(any())).thenThrow(Exception('storage')),
      build: build,
      act: (b) => b.add(const SetPin('5678', currentPin: '1234')),
      verify: (_) =>
          expect(store.calls, ['rekey:1234>5678', 'rekey:5678>1234']),
    );

    blocTest<AuthBloc, AuthState>(
      'a section that cannot be re-sealed keeps the old PIN',
      setUp: () =>
          store.failWith = const SecureStoreException(VaultFailure.failed),
      build: build,
      act: (b) => b.add(const SetPin('5678', currentPin: '1234')),
      verify: (_) => verifyNever(() => repo.setPin(any())),
    );

    blocTest<AuthBloc, AuthState>(
      'recovering a forgotten PIN deletes the section (owner\'s rule)',
      setUp: () {
        when(
          () => repo.validateRecoveryCode(any()),
        ).thenAnswer((_) async => true);
        when(() => repo.clearAuth()).thenAnswer((_) async {});
      },
      build: build,
      act: (b) => b.add(const RecoverWithCode('ABCD-EFGH-JKLM')),
      expect: () => [const AuthLoading(), const AuthNotSet()],
      verify: (_) => expect(store.calls, ['reset']),
    );

    blocTest<AuthBloc, AuthState>(
      'the PIN cannot be removed while a section exists',
      setUp: () => when(() => repo.clearAuth()).thenAnswer((_) async {}),
      build: build,
      act: (b) => b.add(const DisableAuth()),
      verify: (_) => verifyNever(() => repo.clearAuth()),
    );

    blocTest<AuthBloc, AuthState>(
      'without a section, setting a PIN touches no vault',
      setUp: () => store.vaultExists = false,
      build: build,
      act: (b) => b.add(const SetPin('5678')),
      verify: (_) {
        expect(store.calls, isEmpty);
        verify(() => repo.setPin('5678')).called(1);
      },
    );
  });
}
