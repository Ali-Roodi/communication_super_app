import 'package:equatable/equatable.dart';

abstract class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

class CheckAuthStatus extends AuthEvent {
  const CheckAuthStatus();
}

class SetPin extends AuthEvent {
  final String pin;

  const SetPin(this.pin);

  @override
  List<Object?> get props => [pin];
}

class ValidatePin extends AuthEvent {
  final String pin;

  const ValidatePin(this.pin);

  @override
  List<Object?> get props => [pin];
}

class SetPattern extends AuthEvent {
  final List<int> pattern;

  const SetPattern(this.pattern);

  @override
  List<Object?> get props => [pattern];
}

class ValidatePattern extends AuthEvent {
  final List<int> pattern;

  const ValidatePattern(this.pattern);

  @override
  List<Object?> get props => [pattern];
}

class Authenticate extends AuthEvent {
  const Authenticate();
}

class Logout extends AuthEvent {
  const Logout();
}

class ClearAuth extends AuthEvent {
  const ClearAuth();
}

class LockApp extends AuthEvent {
  const LockApp();
}


