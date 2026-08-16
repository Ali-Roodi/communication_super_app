import 'package:equatable/equatable.dart';
import '../models/auth_type.dart';

abstract class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class AuthNotSet extends AuthState {
  const AuthNotSet();
}

class AuthSet extends AuthState {
  final AuthType authType;

  const AuthSet(this.authType);

  @override
  List<Object?> get props => [authType];
}

class AuthAuthenticated extends AuthState {
  const AuthAuthenticated();
}

class AuthUnauthenticated extends AuthState {
  final String? error;

  const AuthUnauthenticated({this.error});

  @override
  List<Object?> get props => [error];
}

/// A recovery code was just minted and must be shown to the user — this is
/// the only moment it exists in readable form.
class AuthRecoveryCodeIssued extends AuthState {
  final String code;

  /// True when the code was issued as part of setting a PIN (the setup flow
  /// continues into the app afterwards), false when it was regenerated from
  /// Settings.
  final bool duringSetup;

  const AuthRecoveryCodeIssued(this.code, {this.duringSetup = false});

  @override
  List<Object?> get props => [code, duringSetup];
}

class AuthValidationFailure extends AuthState {
  final String error;

  const AuthValidationFailure(this.error);

  @override
  List<Object?> get props => [error];
}
