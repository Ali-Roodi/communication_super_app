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

class AuthValidationSuccess extends AuthState {
  const AuthValidationSuccess();
}

class AuthValidationFailure extends AuthState {
  final String error;

  const AuthValidationFailure(this.error);

  @override
  List<Object?> get props => [error];
}

























