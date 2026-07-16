import 'package:flutter_bloc/flutter_bloc.dart';
import 'auth_event.dart';
import 'auth_state.dart';
import '../models/auth_type.dart';
import '../repositories/auth_repository.dart';
import 'package:communication_super_app/core/services/app_lock_service.dart';

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final AuthRepository _repository;
  final AppLockService _lockService = AppLockService();

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
        emit(AuthSet(authType));
      }
    }
  }

  Future<void> _onSetPin(SetPin event, Emitter<AuthState> emit) async {
    emit(const AuthLoading());
    try {
      await _repository.setPin(event.pin);
      // Setting a PIN re-arms the lock even if setup was skipped before.
      await _repository.setAuthSkipped(false);
      // After setting PIN, automatically authenticate the user
      await _repository.setAuthenticated(true);
      emit(const AuthAuthenticated());
    } catch (e) {
      emit(AuthValidationFailure(e.toString()));
    }
  }

  /// «ادامه بدون رمز» — enter the app; never re-prompt setup on launch.
  Future<void> _onSkipAuthSetup(
    SkipAuthSetup event,
    Emitter<AuthState> emit,
  ) async {
    await _repository.setAuthSkipped(true);
    emit(const AuthAuthenticated());
  }

  /// «حذف رمز عبور» from Settings. Emits AuthAuthenticated (not AuthNotSet):
  /// the user is inside the app; showing the setup screen again would be
  /// wrong, and the skipped flag keeps future launches unprompted.
  Future<void> _onDisableAuth(
    DisableAuth event,
    Emitter<AuthState> emit,
  ) async {
    await _repository.clearAuth();
    await _repository.setAuthSkipped(true);
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
      emit(const AuthValidationFailure('Invalid PIN'));
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
      emit(const AuthValidationFailure('Invalid pattern'));
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
      emit(AuthSet(authType));
    }
  }

  Future<void> _onLogout(Logout event, Emitter<AuthState> emit) async {
    await _repository.setAuthenticated(false);
    final authType = await _repository.getAuthType();
    emit(AuthSet(authType));
  }

  Future<void> _onClearAuth(ClearAuth event, Emitter<AuthState> emit) async {
    await _repository.clearAuth();
    emit(const AuthNotSet());
  }

  Future<void> _onLockApp(LockApp event, Emitter<AuthState> emit) async {
    await _lockService.lock();
    await _repository.setAuthenticated(false);
    emit(const AuthUnauthenticated());
  }
}
