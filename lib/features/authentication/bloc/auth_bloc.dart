import 'package:flutter_bloc/flutter_bloc.dart';
import 'auth_event.dart';
import 'auth_state.dart';
import '../models/auth_type.dart';
import '../repositories/auth_repository.dart';
import '../repositories/pin_attempt_limiter.dart';
import 'package:communication_super_app/core/services/app_lock_service.dart';
import 'package:communication_super_app/core/services/pin_handoff.dart';
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final AuthRepository _repository;
  final AppLockService _lockService = AppLockService();

  /// The secure section, which opens with the app PIN — so every change to
  /// that PIN has to keep it in step. Null only in tests that do not involve
  /// it (the app always passes [SecureStore.instance]).
  final SecureStore? _secureStore;

  AuthBloc(this._repository, {SecureStore? secureStore})
    : _secureStore = secureStore,
      super(const AuthInitial()) {
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

  /// Whether a secure section exists. A failure to find out counts as yes:
  /// guessing "no" here is what would orphan it.
  Future<bool> _hasSecureSection() async {
    final store = _secureStore;
    if (store == null) return false;
    try {
      return await store.exists();
    } catch (_) {
      return true;
    }
  }

  Future<void> _onSetPin(SetPin event, Emitter<AuthState> emit) async {
    emit(const AuthLoading());
    final store = _secureStore;
    final rekeyFrom = event.currentPin;
    final hasSection = await _hasSecureSection();
    if (hasSection) {
      // Re-seal the section's key under the new PIN BEFORE the PIN changes,
      // and only with the right old one: an app PIN that no longer opens the
      // section is a section lost.
      if (rekeyFrom == null || !await _repository.validatePin(rekeyFrom)) {
        emit(const AuthValidationFailure('رمز فعلی نادرست است'));
        return;
      }
      try {
        await store!.rekey(rekeyFrom, event.pin);
      } catch (_) {
        emit(
          const AuthValidationFailure(
            'کلید بخش امن به‌روز نشد؛ رمز تغییر نکرد',
          ),
        );
        return;
      }
    }
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
      emit(AuthRecoveryCodeIssued(code, duringSetup: true));
      emit(const AuthAuthenticated());
    } catch (e) {
      // The section was re-sealed for a PIN that did not get saved: seal it
      // back, or the (unchanged) app PIN would no longer open it.
      if (hasSection && rekeyFrom != null) {
        try {
          await store!.rekey(event.pin, rekeyFrom);
        } catch (_) {}
      }
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
    // The owner's rule: a forgotten PIN loses the secure section. Its key is
    // sealed under the PIN being discarded here, so nothing could open it
    // again anyway — delete it rather than leave an unopenable vault behind.
    if (await _hasSecureSection()) {
      try {
        await _secureStore!.reset();
      } catch (_) {}
    }
    await _repository.clearAuth();
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
    // The secure section opens with this PIN. Settings refuses to offer the
    // removal while one exists; this is the backstop.
    if (await _hasSecureSection()) {
      emit(
        const AuthValidationFailure(
          'تا وقتی بخش امن وجود دارد، رمز برنامه حذف نمی‌شود',
        ),
      );
      emit(const AuthAuthenticated());
      return;
    }
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
      // For «پیام رمز جدید» only: see PinHandoff.
      PinHandoff.instance.offer(event.pin);
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
    emit(const AuthNotSet());
  }

  Future<void> _onLockApp(LockApp event, Emitter<AuthState> emit) async {
    await _lockService.lock();
    await _repository.setAuthenticated(false);
    emit(const AuthUnauthenticated());
  }
}
