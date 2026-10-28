import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/services/app_handoff.dart';
import 'package:communication_super_app/features/authentication/models/pin_policy.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/repositories/pin_attempt_limiter.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/security/services/intruder_reporter.dart';
import '../repositories/secure_store.dart';
import '../services/secure_vault_service.dart';

// ── Events ──────────────────────────────────────────────────────────────────

abstract class SecureSessionEvent extends Equatable {
  const SecureSessionEvent();
  @override
  List<Object?> get props => [];
}

/// Re-reads where the section stands (edition, vault, biometric). Cheap; sent
/// at startup, on edition changes, and on every resume.
class SecureSessionRefresh extends SecureSessionEvent {
  const SecureSessionRefresh();
}

/// Creates the section under [pin], its own PIN, and opens it.
class SecureCreateRequested extends SecureSessionEvent {
  final String pin;
  const SecureCreateRequested(this.pin);
  @override
  List<Object?> get props => [pin];
}

/// Opens the section with its PIN.
class SecureUnlockRequested extends SecureSessionEvent {
  final String pin;
  const SecureUnlockRequested(this.pin);
  @override
  List<Object?> get props => [pin];
}

/// Opens the section with a strong biometric. [done] is told how it ended —
/// the key on the lock screen needs the outcome, not just the state.
class SecureBiometricUnlockRequested extends SecureSessionEvent {
  final Completer<SecureBiometricOutcome>? done;
  const SecureBiometricUnlockRequested({this.done});
}

/// Checks the section PIN without opening anything — the first step of
/// changing it, or of turning the fingerprint on. Through the section's
/// attempt budget like an unlock. [done] gets null when right, otherwise what
/// to say.
class SecureVerifyPinRequested extends SecureSessionEvent {
  final String pin;
  final Completer<String?> done;
  const SecureVerifyPinRequested(this.pin, this.done);
}

/// «تغییر رمز بخش امن». [done] gets null on success, otherwise what to say.
class SecureChangePinRequested extends SecureSessionEvent {
  final String currentPin;
  final String newPin;
  final Completer<String?> done;
  const SecureChangePinRequested(this.currentPin, this.newPin, this.done);
}

/// «باز کردن با اثر انگشت» on ([pin] is the section PIN) or off. [done] gets
/// null on success, otherwise what to say (an empty string: nothing to say,
/// the user cancelled).
class SecureBiometricToggleRequested extends SecureSessionEvent {
  final bool enable;
  final String? pin;
  final Completer<String?> done;
  const SecureBiometricToggleRequested(this.enable, this.done, {this.pin});
}

/// The lock icon, tapped while open.
class SecureLockRequested extends SecureSessionEvent {
  const SecureLockRequested();
}

/// The app left the foreground: lock now, keep the window secure until the
/// next resume.
class SecureAppBackgrounded extends SecureSessionEvent {
  const SecureAppBackgrounded();
}

class SecureAppResumed extends SecureSessionEvent {
  const SecureAppResumed();
}

/// Deletes the section and everything in it — on purpose, or because its PIN
/// is forgotten («رمز بخش امن را فراموش کرده‌ام»).
class SecureResetRequested extends SecureSessionEvent {
  const SecureResetRequested();
}

// ── State ───────────────────────────────────────────────────────────────────

enum SecureStatus {
  /// This edition has no secure section (commercial), or not known yet.
  unavailable,

  /// The section has not been created yet; creating it sets its PIN.
  notCreated,

  locked,
  unlocked,

  /// The vault exists but cannot be opened any more (its Keystore key is gone,
  /// or the file/database is damaged). Only a reset gets out of this.
  broken,
}

/// Why the last unlock attempt failed.
enum SecureFailure { wrongPin, lockedOut, broken, failed }

/// How a biometric attempt at the section ended.
enum SecureBiometricOutcome {
  unlocked,

  /// Dismissed, or «با رمز» chosen.
  cancelled,

  /// A finger was enrolled (or all removed) since it was turned on: it has
  /// been turned off, only the PIN opens now.
  invalidated,

  /// Off, unavailable right now, locked out by the phone, or failed.
  unavailable,
}

class SecureSessionState extends Equatable {
  final SecureStatus status;
  final bool busy;
  final SecureFailure? lastFailure;

  /// The user-facing sentence for [lastFailure] (the lockout one carries the
  /// remaining time).
  final String? failureMessage;

  /// Failed attempts in this session; makes each failure a distinct state.
  final int failures;

  /// «باز کردن با اثر انگشت» is on for the section.
  final bool biometricOn;

  /// What the phone can offer: a strong biometric only.
  final BiometricAvailability biometricAvailability;

  const SecureSessionState({
    this.status = SecureStatus.unavailable,
    this.busy = false,
    this.lastFailure,
    this.failureMessage,
    this.failures = 0,
    this.biometricOn = false,
    this.biometricAvailability = BiometricAvailability.unsupported,
  });

  bool get isUnlocked => status == SecureStatus.unlocked;

  /// A section exists (open, closed or unopenable).
  bool get exists =>
      status == SecureStatus.locked ||
      status == SecureStatus.unlocked ||
      status == SecureStatus.broken;

  SecureSessionState copyWith({
    SecureStatus? status,
    bool? busy,
    SecureFailure? lastFailure,
    String? failureMessage,
    bool clearFailure = false,
    int? failures,
    bool? biometricOn,
    BiometricAvailability? biometricAvailability,
  }) => SecureSessionState(
    status: status ?? this.status,
    busy: busy ?? this.busy,
    lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
    failureMessage: clearFailure
        ? null
        : (failureMessage ?? this.failureMessage),
    failures: failures ?? this.failures,
    biometricOn: biometricOn ?? this.biometricOn,
    biometricAvailability: biometricAvailability ?? this.biometricAvailability,
  );

  @override
  List<Object?> get props => [
    status,
    busy,
    lastFailure,
    failureMessage,
    failures,
    biometricOn,
    biometricAvailability,
  ];
}

// ── Bloc ────────────────────────────────────────────────────────────────────

/// The secure section's session: whether it exists, and whether it is open.
///
/// Rules:
/// * it opens with **its own PIN** (design decision, 1405/07/27) — 6 digits,
///   never the app PIN, with its own attempt budget
///   ([PinAttemptLimiter.secureSection]) checked before the vault's PBKDF2
///   runs. The app PIN — set, changed, removed or recovered — never touches
///   it; or, with «باز کردن با اثر انگشت», with a strong biometric that
///   releases a second, Keystore-sealed copy of the key (`SecureBiometric`);
/// * it locks the moment the app leaves the foreground;
/// * a forgotten section PIN loses its content — there is no recovery path
///   into it (design decision, 1405/07/05).
///
/// While open, the window is FLAG_SECURE. After a background lock the flag is
/// kept until the next resume: the recents thumbnail is taken on the way out,
/// and clearing the flag first would let it capture the open section.
class SecureSessionBloc extends Bloc<SecureSessionEvent, SecureSessionState> {
  SecureSessionBloc({
    required EditionBloc edition,
    SecureStore? store,
    AuthRepository? auth,
    PinAttemptLimiter? limiter,
  }) : _edition = edition,
       _store = store ?? SecureStore.instance,
       _auth = auth ?? AuthRepository(),
       _limiter = limiter ?? PinAttemptLimiter.secureSection(),
       super(const SecureSessionState()) {
    on<SecureSessionRefresh>(_onRefresh);
    on<SecureCreateRequested>(_onCreate);
    on<SecureUnlockRequested>(_onUnlock);
    on<SecureBiometricUnlockRequested>(_onBiometricUnlock);
    on<SecureVerifyPinRequested>(_onVerifyPin);
    on<SecureChangePinRequested>(_onChangePin);
    on<SecureBiometricToggleRequested>(_onBiometricToggle);
    on<SecureLockRequested>(_onLock);
    on<SecureAppBackgrounded>(_onBackgrounded);
    on<SecureAppResumed>(_onResumed);
    on<SecureResetRequested>(_onReset);
    _editionSub = edition.stream
        .map((s) => s.hasSecureFeatures)
        .distinct()
        .listen((_) => add(const SecureSessionRefresh()));
  }

  final EditionBloc _edition;
  final SecureStore _store;
  final AuthRepository _auth;
  final PinAttemptLimiter _limiter;
  late final StreamSubscription<bool> _editionSub;

  /// FLAG_SECURE was left on by a background lock; clear it on resume.
  bool _windowSecureLeftOn = false;

  /// The open database for the secure features, or null while locked.
  SecureStore get store => _store;

  static const String _wrongPin = 'رمز بخش امن اشتباه است';
  static const String _openFailed =
      'باز کردن بخش امن انجام نشد؛ دوباره تلاش کنید';
  static const String _sameAsAppPin =
      'رمز بخش امن باید با رمز برنامه فرق داشته باشد';
  static const String _invalidated =
      'اثر انگشت گوشی تغییر کرده است؛ برای امنیت، باز کردن بخش امن با اثر '
      'انگشت خاموش شد. با رمز بخش امن وارد شوید';

  /// Where the section stands. A vault found [SecureStatus.broken] stays so
  /// until it is reset ([keepBroken] false only for the reset itself).
  Future<SecureStatus> _currentStatus({bool keepBroken = true}) async {
    if (!_edition.state.hasSecureFeatures) return SecureStatus.unavailable;
    if (_store.isOpen) return SecureStatus.unlocked;
    final bool exists;
    try {
      exists = await _store.exists();
    } on SecureStoreException {
      return SecureStatus.broken;
    }
    if (!exists) return SecureStatus.notCreated;
    return keepBroken && state.status == SecureStatus.broken
        ? SecureStatus.broken
        : SecureStatus.locked;
  }

  /// The status with the biometric facts beside it.
  Future<SecureSessionState> _read() async {
    final status = await _currentStatus();
    if (status == SecureStatus.unavailable) {
      return state.copyWith(status: status, biometricOn: false);
    }
    final exists = status != SecureStatus.notCreated;
    return state.copyWith(
      status: status,
      biometricOn: exists && await _store.biometricEnabled(),
      biometricAvailability: await _store.biometricStatus(),
    );
  }

  Future<void> _onRefresh(
    SecureSessionRefresh event,
    Emitter<SecureSessionState> emit,
  ) async {
    // Losing the secure features while open (deactivation) closes the section.
    if (!_edition.state.hasSecureFeatures && _store.isOpen) {
      await _closeSection(keepWindowSecure: false);
    }
    emit(await _read());
  }

  Future<void> _onCreate(
    SecureCreateRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    if (state.busy) return;
    final status = await _currentStatus();
    if (status != SecureStatus.notCreated) {
      emit(state.copyWith(status: status));
      return;
    }
    if (event.pin.length != PinPolicy.secureLength) return;
    emit(state.copyWith(status: status, busy: true, clearFailure: true));
    if (await _auth.isAppPin(event.pin)) {
      emit(_failed(SecureFailure.wrongPin, _sameAsAppPin));
      return;
    }
    await _opening(emit, status, () => _store.create(event.pin));
  }

  Future<void> _onUnlock(
    SecureUnlockRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    if (state.busy) return;
    final status = await _currentStatus();
    if (status != SecureStatus.locked) {
      emit(state.copyWith(status: status));
      return;
    }
    emit(state.copyWith(status: status, busy: true, clearFailure: true));
    // The budget first: PBKDF2 never runs for a guess it would refuse.
    final wait = await _limiter.retryAfter();
    if (wait != null) {
      emit(
        _failed(
          SecureFailure.lockedOut,
          PinAttemptLimiter.lockoutMessage(wait),
        ),
      );
      return;
    }
    await _opening(emit, status, () => _store.unlock(event.pin));
  }

  Future<void> _onBiometricUnlock(
    SecureBiometricUnlockRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    void answer(SecureBiometricOutcome outcome) {
      final done = event.done;
      if (done != null && !done.isCompleted) done.complete(outcome);
    }

    final status = await _currentStatus();
    if (state.busy || status != SecureStatus.locked || !state.biometricOn) {
      answer(SecureBiometricOutcome.unavailable);
      return;
    }
    emit(state.copyWith(status: status, busy: true, clearFailure: true));
    try {
      await _store.setSecureWindow(true);
      // The system prompt may pause the activity; a pause the app started
      // itself must not lock the very section it is opening.
      await AppHandoff.run(_store.unlockWithBiometric);
      _windowSecureLeftOn = false;
      await _limiter.recordSuccess();
      emit(
        state.copyWith(
          status: SecureStatus.unlocked,
          busy: false,
          clearFailure: true,
          failures: 0,
        ),
      );
      answer(SecureBiometricOutcome.unlocked);
    } on SecureStoreException catch (e) {
      await _store.setSecureWindow(false);
      switch (e.failure) {
        case VaultFailure.bioCancelled:
          emit(state.copyWith(busy: false));
          answer(SecureBiometricOutcome.cancelled);
        case VaultFailure.bioInvalidated:
        case VaultFailure.bioOff:
          emit(
            state.copyWith(
              busy: false,
              biometricOn: false,
              lastFailure: SecureFailure.failed,
              failureMessage: _invalidated,
              failures: state.failures + 1,
            ),
          );
          answer(SecureBiometricOutcome.invalidated);
        case VaultFailure.keyLost:
        case VaultFailure.corrupt:
          emit(
            _failed(
              SecureFailure.broken,
              'بخش امن قابل باز شدن نیست',
              status: SecureStatus.broken,
            ),
          );
          answer(SecureBiometricOutcome.unavailable);
        default:
          emit(state.copyWith(busy: false));
          answer(SecureBiometricOutcome.unavailable);
      }
    } catch (_) {
      await _store.lock();
      await _store.setSecureWindow(false);
      emit(state.copyWith(busy: false));
      answer(SecureBiometricOutcome.unavailable);
    }
  }

  /// Opens (or creates) the section through [open], with FLAG_SECURE set
  /// before any secure content can reach the screen.
  Future<void> _opening(
    Emitter<SecureSessionState> emit,
    SecureStatus status,
    Future<void> Function() open,
  ) async {
    try {
      await _store.setSecureWindow(true);
      await open();
      _windowSecureLeftOn = false;
      await _limiter.recordSuccess();
      IntruderReporter.rightPin();
      emit(
        state.copyWith(
          status: SecureStatus.unlocked,
          busy: false,
          clearFailure: true,
          failures: 0,
          biometricOn: await _store.biometricEnabled(),
        ),
      );
    } on SecureStoreException catch (e) {
      await _store.setSecureWindow(false);
      switch (e.failure) {
        case VaultFailure.wrongPin:
          final failures = await _limiter.recordFailure();
          // Every third in a row, the cameras — if the user turned it on.
          IntruderReporter.wrongPin(failures);
          final wait = await _limiter.retryAfter();
          emit(
            wait == null
                ? _failed(SecureFailure.wrongPin, _wrongPin)
                : _failed(
                    SecureFailure.lockedOut,
                    PinAttemptLimiter.lockoutMessage(wait),
                  ),
          );
        case VaultFailure.keyLost:
        case VaultFailure.corrupt:
          emit(
            _failed(
              SecureFailure.broken,
              'بخش امن قابل باز شدن نیست',
              status: SecureStatus.broken,
            ),
          );
        default:
          emit(_failed(SecureFailure.failed, _openFailed, status: status));
      }
    } catch (_) {
      // Anything unforeseen (I/O, a platform error): never leave the section
      // half open, the window flag set, or the screen stuck on "busy".
      await _store.lock();
      await _store.setSecureWindow(false);
      emit(_failed(SecureFailure.failed, _openFailed, status: status));
    }
  }

  SecureSessionState _failed(
    SecureFailure failure,
    String message, {
    SecureStatus? status,
  }) => state.copyWith(
    status: status,
    busy: false,
    lastFailure: failure,
    failureMessage: message,
    failures: state.failures + 1,
  );

  Future<void> _onVerifyPin(
    SecureVerifyPinRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    void answer(String? message) {
      if (!event.done.isCompleted) event.done.complete(message);
    }

    if (!state.exists || state.status == SecureStatus.broken) {
      answer('بخش امن وجود ندارد');
      return;
    }
    final wait = await _limiter.retryAfter();
    if (wait != null) {
      answer(PinAttemptLimiter.lockoutMessage(wait));
      return;
    }
    try {
      await _store.verifyPin(event.pin);
      await _limiter.recordSuccess();
      answer(null);
    } on SecureStoreException catch (e) {
      if (e.failure != VaultFailure.wrongPin) {
        answer(_openFailed);
        return;
      }
      IntruderReporter.wrongPin(await _limiter.recordFailure());
      final wait = await _limiter.retryAfter();
      answer(wait == null ? _wrongPin : PinAttemptLimiter.lockoutMessage(wait));
    } catch (_) {
      answer(_openFailed);
    }
  }

  Future<void> _onChangePin(
    SecureChangePinRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    void answer(String? message) {
      if (!event.done.isCompleted) event.done.complete(message);
    }

    if (!state.exists || state.status == SecureStatus.broken) {
      answer('بخش امن وجود ندارد');
      return;
    }
    if (event.newPin.length != PinPolicy.secureLength) {
      answer('رمز بخش امن ۶ رقم است');
      return;
    }
    final wait = await _limiter.retryAfter();
    if (wait != null) {
      answer(PinAttemptLimiter.lockoutMessage(wait));
      return;
    }
    if (await _auth.isAppPin(event.newPin)) {
      answer(_sameAsAppPin);
      return;
    }
    try {
      // The same data key, sealed under the new PIN; the database and the
      // biometric copy are untouched.
      await _store.rekey(event.currentPin, event.newPin);
      await _limiter.recordSuccess();
      answer(null);
    } on SecureStoreException catch (e) {
      if (e.failure == VaultFailure.wrongPin) {
        IntruderReporter.wrongPin(await _limiter.recordFailure());
        final wait = await _limiter.retryAfter();
        answer(
          wait == null
              ? 'رمز فعلی بخش امن اشتباه است'
              : PinAttemptLimiter.lockoutMessage(wait),
        );
      } else {
        answer('رمز تغییر نکرد؛ دوباره تلاش کنید');
      }
    } catch (_) {
      answer('رمز تغییر نکرد؛ دوباره تلاش کنید');
    }
  }

  Future<void> _onBiometricToggle(
    SecureBiometricToggleRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    void answer(String? message) {
      if (!event.done.isCompleted) event.done.complete(message);
    }

    if (!event.enable) {
      try {
        await _store.disableBiometric();
      } catch (_) {}
      emit(await _read());
      answer(null);
      return;
    }
    final pin = event.pin;
    if (pin == null || !state.exists || state.status == SecureStatus.broken) {
      answer('بخش امن وجود ندارد');
      return;
    }
    final wait = await _limiter.retryAfter();
    if (wait != null) {
      answer(PinAttemptLimiter.lockoutMessage(wait));
      return;
    }
    try {
      await AppHandoff.run(() => _store.enableBiometric(pin));
      await _limiter.recordSuccess();
      answer(null);
    } on SecureStoreException catch (e) {
      switch (e.failure) {
        case VaultFailure.wrongPin:
          IntruderReporter.wrongPin(await _limiter.recordFailure());
          final wait = await _limiter.retryAfter();
          answer(
            wait == null ? _wrongPin : PinAttemptLimiter.lockoutMessage(wait),
          );
        case VaultFailure.bioCancelled:
          answer('');
        case VaultFailure.bioInvalidated:
          answer('ابتدا در تنظیمات گوشی اثر انگشت ثبت کنید');
        case VaultFailure.bioLockedOut:
          answer('تلاش‌های زیادی انجام شد؛ کمی بعد دوباره امتحان کنید');
        default:
          answer('فعال نشد؛ دوباره امتحان کنید');
      }
    } catch (_) {
      answer('فعال نشد؛ دوباره امتحان کنید');
    }
    emit(await _read());
  }

  Future<void> _onLock(
    SecureLockRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    if (!_store.isOpen) return;
    await _closeSection(keepWindowSecure: false);
    emit((await _read()).copyWith(clearFailure: true));
  }

  Future<void> _onBackgrounded(
    SecureAppBackgrounded event,
    Emitter<SecureSessionState> emit,
  ) async {
    if (!_store.isOpen) return;
    await _closeSection(keepWindowSecure: true);
    emit(state.copyWith(status: await _currentStatus(), clearFailure: true));
  }

  Future<void> _onResumed(
    SecureAppResumed event,
    Emitter<SecureSessionState> emit,
  ) async {
    if (_windowSecureLeftOn && !_store.isOpen) {
      _windowSecureLeftOn = false;
      await _store.setSecureWindow(false);
    }
    // The phone's biometrics may have changed while the app was away.
    emit(await _read());
  }

  Future<void> _onReset(
    SecureResetRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    emit(state.copyWith(busy: true));
    try {
      await _store.reset();
    } on SecureStoreException {
      // The vault may already be half gone; what matters is that nothing of it
      // is left open, and the status below says what is left.
    }
    await _store.setSecureWindow(false);
    _windowSecureLeftOn = false;
    // A new section starts with a clean budget.
    await _limiter.recordSuccess();
    emit(
      SecureSessionState(
        status: await _currentStatus(keepBroken: false),
        biometricAvailability: await _store.biometricStatus(),
      ),
    );
  }

  Future<void> _closeSection({required bool keepWindowSecure}) async {
    await _store.lock();
    if (keepWindowSecure) {
      _windowSecureLeftOn = true;
    } else {
      await _store.setSecureWindow(false);
    }
  }

  @override
  Future<void> close() async {
    await _editionSub.cancel();
    if (_store.isOpen) await _store.lock();
    return super.close();
  }
}
