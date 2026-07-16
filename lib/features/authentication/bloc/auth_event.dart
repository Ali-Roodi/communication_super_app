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

/// First-entry choice «ادامه بدون رمز»: skip auth setup permanently (until a
/// PIN is set from Settings) and enter the app.
class SkipAuthSetup extends AuthEvent {
  const SkipAuthSetup();
}

/// Settings action «حذف رمز عبور»: clears the credentials AND marks setup as
/// skipped, so the next launch goes straight in instead of re-prompting.
class DisableAuth extends AuthEvent {
  const DisableAuth();
}

class LockApp extends AuthEvent {
  const LockApp();
}
