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

/// «رمز را فراموش کرده‌ام»: the user typed the recovery code shown at setup.
///
/// On a match the stored credential is cleared and the app drops to the
/// set-a-PIN flow. It does NOT unlock the app as-is — a code that has been
/// written on paper should not be a second password.
class RecoverWithCode extends AuthEvent {
  final String code;

  const RecoverWithCode(this.code);

  @override
  List<Object?> get props => [code];
}

/// Settings → «کد بازیابی جدید»: mints a fresh code (invalidating the old one)
/// and shows it once. Only reachable from inside an unlocked app.
class RegenerateRecoveryCode extends AuthEvent {
  const RegenerateRecoveryCode();
}
