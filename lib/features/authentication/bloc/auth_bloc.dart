import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'auth_event.dart';
import 'auth_state.dart';
import '../models/auth_type.dart';
import '../repositories/auth_repository.dart';
import '../repositories/pin_attempt_limiter.dart';
import '../services/biometric_unlock.dart';
import '../services/notification_privacy_sync.dart';
import 'package:communication_super_app/features/security/services/intruder_reporter.dart';

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final AuthRepository _repository;

  /// The app PIN only. The secure section has its own PIN
  /// (`SecureSessionBloc`), so nothing here — setting, changing, removing or
  /// recovering this one — ever touches it.
  AuthBloc(this._repository) : super(const AuthInitial()) {
    on<CheckAuthStatus>(_onCheckAuthStatus);
    on<SetPin>(_onSetPin);
    on<ValidatePin>(_onValidatePin);
    on<SetPattern>(_onSetPattern);
    on<ValidatePattern>(_onValidatePattern);
    on<Authenticate>(_onAuthenticate);
    on<Logout>(_onLogout);
    on<ClearAuth>(_onClearAuth);
    on<SkipAuthSetup>(_onSkipAuthSetup);
    on<DisableAuth>(_onDisableAuth);
    on<LockApp>(_onLockApp);
    on<RecoverWithCode>(_onRecoverWithCode);
    on<RegenerateRecoveryCode>(_onRegenerateRecoveryCode);
    on<BiometricUnlocked>(_onBiometricUnlocked);
  }

  /// The PIN screen was passed with the phone's biometric. Re-checked here
  /// rather than trusted: the event must not open an app whose setting was
  /// switched off (or whose PIN was removed) in the meantime.
  Future<void> _onBiometricUnlocked(
    BiometricUnlocked event,
    Emitter<AuthState> emit,
  ) async {
    if (!await BiometricUnlock(auth: _repository).isEnabled()) return;
    await _repository.setAuthenticated(true);
    // «گزارش در اولین ورود موفق» (row 32) — the owner coming in by finger is
    // as much a first successful entry as by PIN.
    IntruderReporter.rightPin();
    emit(const AuthAuthenticated());
  }

  Future<void> _onCheckAuthStatus(
    CheckAuthStatus event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    final authType = await _repository.getAuthType();
    if (authType == AuthType.none) {
      // Auth is OPTIONAL: a user who chose «ادامه بدون رمز» (or removed the
      // PIN from Settings) goes straight in — no re-prompt on every launch.
      if (await _repository.isAuthSkipped()) {
        emit(const AuthAuthenticated());
      } else {
        emit(const AuthNotSet());
      }
    } else {
      final isAuthenticated = await _repository.isAuthenticated();
      if (isAuthenticated) {
        emit(const AuthAuthenticated());
      } else {
        emit(await _lockedState(authType));
      }
    }
  }

  /// The state a PIN screen is drawn for, carrying the stored PIN's length.
  Future<AuthSet> _lockedState([AuthType? type]) async => AuthSet(
    type ?? await _repository.getAuthType(),
    pinLength: await _repository.pinLength(),
  );

  Future<void> _onSetPin(SetPin event, Emitter<AuthState> emit) async {
    emit(const AuthLoading());
    try {
      await _repository.setPin(event.pin);
      // Setting a PIN re-arms the lock even if setup was skipped before.
      await _repository.setAuthSkipped(false);
      // After setting PIN, automatically authenticate the user
      await _repository.setAuthenticated(true);
      // A new recovery code is minted with every new PIN, and it is emitted
      // BEFORE AuthAuthenticated so the setup screen can show it — this is the
      // only moment it is readable. Without it, forgetting the PIN is a
      // permanent lockout: there is no account and no server to reset from.
      final code = await _repository.regenerateRecoveryCode();
      // A PIN now exists: notifications stop naming senders (when the switch
      // is on, which is its default).
      unawaited(NotificationPrivacySync.sync());
      emit(AuthRecoveryCodeIssued(code, duringSetup: true));
      emit(const AuthAuthenticated());
    } catch (e) {
      emit(AuthValidationFailure(e.toString()));
    }
  }

  /// «رمز را فراموش کرده‌ام». A correct code clears the credential and drops
  /// the app to the set-a-PIN flow; it never unlocks the app directly, because
  /// a code the user wrote on paper must not become a second password.
  Future<void> _onRecoverWithCode(
    RecoverWithCode event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    final valid = await _repository.validateRecoveryCode(event.code);
    if (!valid) {
      final authType = await _repository.getAuthType();
      emit(const AuthValidationFailure('کد بازیابی نادرست است'));
      emit(await _lockedState(authType));
      return;
    }
    await _repository.clearAuth();
    unawaited(NotificationPrivacySync.sync());
    emit(const AuthNotSet());
  }

  Future<void> _onRegenerateRecoveryCode(
    RegenerateRecoveryCode event,
    Emitter<AuthState> emit,
  ) async {
    final code = await _repository.regenerateRecoveryCode();
    emit(AuthRecoveryCodeIssued(code));
    // The user is already inside the app; hand the state back so nothing
    // navigates away behind the code sheet.
    emit(const AuthAuthenticated());
  }

  /// «ادامه بدون رمز» — enter the app; never re-prompt setup on launch.
  Future<void> _onSkipAuthSetup(
    SkipAuthSetup event,
    Emitter<AuthState> emit,
  ) async {
    await _repository.setAuthSkipped(true);
    emit(const AuthAuthenticated());
  }

  /// «حذف رمز عبور» from Settings. Ends in AuthAuthenticated (not
  /// AuthNotSet): the user is inside the app; showing the setup screen again
  /// would be wrong, and the skipped flag keeps future launches unprompted.
  ///
  /// It starts with AuthLoading on purpose. The user is already
  /// AuthAuthenticated, so without it the final emit is equal to the current
  /// state, is dropped, and nothing can tell that the removal has finished —
  /// which is why Settings used to redraw from the storage *before* the PIN
  /// was gone and kept showing «تغییر رمز عبور». AuthWrapperScreen ignores
  /// AuthLoading, so nothing else reacts to it.
  Future<void> _onDisableAuth(
    DisableAuth event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    await _repository.clearAuth();
    await _repository.setAuthSkipped(true);
    unawaited(NotificationPrivacySync.sync());
    emit(const AuthAuthenticated());
  }

  Future<void> _onValidatePin(
    ValidatePin event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    final isValid = await _repository.validatePin(event.pin);
    if (isValid) {
      await _repository.setAuthenticated(true);
      emit(const AuthAuthenticated());
    } else {
      final wait = await _repository.pinRetryAfter();
      emit(
        AuthValidationFailure(
          wait == null
              ? 'رمز عبور اشتباه است'
              : PinAttemptLimiter.lockoutMessage(wait),
        ),
      );
      // Back to the state the PIN screen is drawn for, as [RecoverWithCode]
      // does — a failure is an event to react to, not a place to stay.
      emit(await _lockedState());
    }
  }

  Future<void> _onSetPattern(SetPattern event, Emitter<AuthState> emit) async {
    emit(const AuthLoading());
    try {
      await _repository.setPattern(event.pattern);
      // After setting pattern, automatically authenticate the user
      await _repository.setAuthenticated(true);
      emit(const AuthAuthenticated());
    } catch (e) {
      emit(AuthValidationFailure(e.toString()));
    }
  }

  Future<void> _onValidatePattern(
    ValidatePattern event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    final isValid = await _repository.validatePattern(event.pattern);
    if (isValid) {
      await _repository.setAuthenticated(true);
      emit(const AuthAuthenticated());
    } else {
      emit(const AuthValidationFailure('الگو اشتباه است'));
      emit(await _lockedState());
    }
  }

  Future<void> _onAuthenticate(
    Authenticate event,
    Emitter<AuthState> emit,
  ) async {
    final isAuthenticated = await _repository.isAuthenticated();
    if (isAuthenticated) {
      emit(const AuthAuthenticated());
    } else {
      final authType = await _repository.getAuthType();
      emit(await _lockedState(authType));
    }
  }

  Future<void> _onLogout(Logout event, Emitter<AuthState> emit) async {
    await _repository.setAuthenticated(false);
    final authType = await _repository.getAuthType();
    emit(await _lockedState(authType));
  }

  Future<void> _onClearAuth(ClearAuth event, Emitter<AuthState> emit) async {
    await _repository.clearAuth();
    unawaited(NotificationPrivacySync.sync());
    emit(const AuthNotSet());
  }

  Future<void> _onLockApp(LockApp event, Emitter<AuthState> emit) async {
    await _repository.setAuthenticated(false);
    emit(const AuthUnauthenticated());
  }
}
