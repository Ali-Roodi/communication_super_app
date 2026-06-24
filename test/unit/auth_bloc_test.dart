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
      'emits AuthNotSet when no auth type is configured',
      setUp: () =>
          when(() => repo.getAuthType()).thenAnswer((_) async => AuthType.none),
      build: build,
      act: (bloc) => bloc.add(const CheckAuthStatus()),
      expect: () => [const AuthLoading(), const AuthNotSet()],
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
      'invalid PIN emits a validation failure',
      setUp: () =>
          when(() => repo.validatePin('0000')).thenAnswer((_) async => false),
      build: build,
      act: (bloc) => bloc.add(const ValidatePin('0000')),
      expect: () => [
        const AuthLoading(),
        const AuthValidationFailure('Invalid PIN'),
      ],
    );
  });
}
