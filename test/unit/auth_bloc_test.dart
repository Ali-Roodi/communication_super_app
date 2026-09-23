import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late _MockAuthRepository repo;

  setUp(() => repo = _MockAuthRepository());

  AuthBloc build() => AuthBloc(repo);

  group('CheckAuthStatus', () {
    blocTest<AuthBloc, AuthState>(
      'emits AuthNotSet when no auth type is configured (setup not skipped)',
      setUp: () {
        when(() => repo.getAuthType()).thenAnswer((_) async => AuthType.none);
        when(() => repo.isAuthSkipped()).thenAnswer((_) async => false);
      },
      build: build,
      act: (bloc) => bloc.add(const CheckAuthStatus()),
      expect: () => [const AuthLoading(), const AuthNotSet()],
    );

    blocTest<AuthBloc, AuthState>(
      'goes straight in (AuthAuthenticated) when setup was skipped',
      setUp: () {
        when(() => repo.getAuthType()).thenAnswer((_) async => AuthType.none);
        when(() => repo.isAuthSkipped()).thenAnswer((_) async => true);
      },
      build: build,
      act: (bloc) => bloc.add(const CheckAuthStatus()),
      expect: () => [const AuthLoading(), const AuthAuthenticated()],
    );

    blocTest<AuthBloc, AuthState>(
      'SkipAuthSetup persists the flag and authenticates',
      setUp: () =>
          when(() => repo.setAuthSkipped(true)).thenAnswer((_) async {}),
      build: build,
      act: (bloc) => bloc.add(const SkipAuthSetup()),
      expect: () => [const AuthAuthenticated()],
      verify: (_) => verify(() => repo.setAuthSkipped(true)).called(1),
    );

    blocTest<AuthBloc, AuthState>(
      'DisableAuth clears credentials, marks skipped, stays authenticated',
      setUp: () {
        when(() => repo.clearAuth()).thenAnswer((_) async {});
        when(() => repo.setAuthSkipped(true)).thenAnswer((_) async {});
      },
      build: build,
      act: (bloc) => bloc.add(const DisableAuth()),
      expect: () => [const AuthAuthenticated()],
      verify: (_) {
        verify(() => repo.clearAuth()).called(1);
        verify(() => repo.setAuthSkipped(true)).called(1);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'emits AuthAuthenticated when a PIN is set and already authenticated',
      setUp: () {
        when(() => repo.getAuthType()).thenAnswer((_) async => AuthType.pin);
        when(() => repo.isAuthenticated()).thenAnswer((_) async => true);
      },
      build: build,
      act: (bloc) => bloc.add(const CheckAuthStatus()),
      expect: () => [const AuthLoading(), const AuthAuthenticated()],
    );

    blocTest<AuthBloc, AuthState>(
      'emits AuthSet when a PIN is set but not yet authenticated',
      setUp: () {
        when(() => repo.getAuthType()).thenAnswer((_) async => AuthType.pin);
        when(() => repo.isAuthenticated()).thenAnswer((_) async => false);
      },
      build: build,
      act: (bloc) => bloc.add(const CheckAuthStatus()),
      expect: () => [const AuthLoading(), const AuthSet(AuthType.pin)],
    );
  });

  group('ValidatePin', () {
    blocTest<AuthBloc, AuthState>(
      'valid PIN authenticates and persists the authenticated flag',
      setUp: () {
        when(() => repo.validatePin('1234')).thenAnswer((_) async => true);
        when(() => repo.setAuthenticated(true)).thenAnswer((_) async {});
      },
      build: build,
      act: (bloc) => bloc.add(const ValidatePin('1234')),
      expect: () => [const AuthLoading(), const AuthAuthenticated()],
      verify: (_) => verify(() => repo.setAuthenticated(true)).called(1),
    );

    blocTest<AuthBloc, AuthState>(
      'invalid PIN reports the failure in Persian and returns to AuthSet',
      setUp: () {
        when(() => repo.validatePin('0000')).thenAnswer((_) async => false);
        when(() => repo.getAuthType()).thenAnswer((_) async => AuthType.pin);
      },
      build: build,
      act: (bloc) => bloc.add(const ValidatePin('0000')),
      // Ending on AuthSet is what keeps the PIN screen on screen; a bloc that
      // stopped on the failure left the app on a blank page.
      expect: () => [
        const AuthLoading(),
        const AuthValidationFailure('رمز عبور اشتباه است'),
        const AuthSet(AuthType.pin),
      ],
    );
  });
}
