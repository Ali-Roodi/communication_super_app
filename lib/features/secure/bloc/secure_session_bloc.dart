import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/models/pin_policy.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/repositories/pin_attempt_limiter.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import '../repositories/secure_store.dart';
import '../services/secure_vault_service.dart';

// ── Events ──────────────────────────────────────────────────────────────────

abstract class SecureSessionEvent extends Equatable {
  const SecureSessionEvent();
  @override
  List<Object?> get props => [];
}

/// Re-reads where the section stands (edition, app PIN, vault). Cheap; sent
/// at startup, on edition changes, and before every unlock.
class SecureSessionRefresh extends SecureSessionEvent {
  const SecureSessionRefresh();
}

/// Opens the section with the app PIN — creating it on first use.
class SecureUnlockRequested extends SecureSessionEvent {
  final String pin;
  const SecureUnlockRequested(this.pin);
  @override
  List<Object?> get props => [pin];
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

/// Deletes the section and everything in it (a lost key, or the user's
/// explicit choice).
class SecureResetRequested extends SecureSessionEvent {
  const SecureResetRequested();
}

// ── State ───────────────────────────────────────────────────────────────────

enum SecureStatus {
  /// This edition has no secure section (commercial), or not known yet.
  unavailable,

  /// The section opens with the app PIN, and none is set.
  needsPin,

  /// The app PIN is shorter than a secure edition requires (a 4-digit PIN set
  /// before activation): the section is not created until it is changed to 6
  /// digits. A section that already exists is never affected by this.
  pinTooShort,

  /// A PIN exists; the section has not been created yet.
  notCreated,

  locked,
  unlocked,

  /// The vault exists but cannot be opened any more (its Keystore key is gone,
  /// or the file/database is damaged). Only a reset gets out of this.
  broken,
}

/// Why the last unlock attempt failed.
enum SecureFailure { wrongPin, lockedOut, broken, failed }

class SecureSessionState extends Equatable {
  final SecureStatus status;
  final bool busy;
  final SecureFailure? lastFailure;

  /// The user-facing sentence for [lastFailure] (the lockout one carries the
  /// remaining time).
  final String? failureMessage;

  /// Failed attempts in this session; makes each failure a distinct state.
  final int failures;

  const SecureSessionState({
    this.status = SecureStatus.unavailable,
    this.busy = false,
    this.lastFailure,
    this.failureMessage,
    this.failures = 0,
  });

  bool get isUnlocked => status == SecureStatus.unlocked;

  SecureSessionState copyWith({
    SecureStatus? status,
    bool? busy,
    SecureFailure? lastFailure,
    String? failureMessage,
    bool clearFailure = false,
    int? failures,
  }) => SecureSessionState(
    status: status ?? this.status,
    busy: busy ?? this.busy,
    lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
    failureMessage: clearFailure
        ? null
        : (failureMessage ?? this.failureMessage),
    failures: failures ?? this.failures,
  );

  @override
  List<Object?> get props => [
    status,
    busy,
    lastFailure,
    failureMessage,
    failures,
  ];
}

// ── Bloc ────────────────────────────────────────────────────────────────────

/// The secure section's session: whether it exists, and whether it is open.
///
/// Rules (owner's decisions, 1405/07/05):
/// * it opens with the **app PIN** — every PIN check goes through the shared
///   attempt budget first ([AuthRepository.validatePin]), so the vault's
///   PBKDF2 never runs for a guess the lock screen would already refuse;
/// * it locks the moment the app leaves the foreground;
/// * a forgotten PIN loses its content — there is no recovery path into it.
///
/// While open, the window is FLAG_SECURE. After a background lock the flag is
/// kept until the next resume: the recents thumbnail is taken on the way out,
/// and clearing the flag first would let it capture the open section.
class SecureSessionBloc extends Bloc<SecureSessionEvent, SecureSessionState> {
  /// [authChanges] is `AuthBloc.stream`: setting, changing, removing or
  /// recovering the app PIN changes what this section can be (it opens with
  /// that PIN), so every authentication change re-reads the status.
  SecureSessionBloc({
    required EditionBloc edition,
    Stream<Object?>? authChanges,
    SecureStore? store,
    AuthRepository? auth,
  }) : _edition = edition,
       _store = store ?? SecureStore.instance,
       _auth = auth ?? AuthRepository(),
       super(const SecureSessionState()) {
    on<SecureSessionRefresh>(_onRefresh);
    on<SecureUnlockRequested>(_onUnlock);
    on<SecureLockRequested>(_onLock);
    on<SecureAppBackgrounded>(_onBackgrounded);
    on<SecureAppResumed>(_onResumed);
    on<SecureResetRequested>(_onReset);
    _editionSub = edition.stream
        .map((s) => s.hasSecureFeatures)
        .distinct()
        .listen((_) => add(const SecureSessionRefresh()));
    _authSub = authChanges?.listen((_) => add(const SecureSessionRefresh()));
  }

  final EditionBloc _edition;
  final SecureStore _store;
  final AuthRepository _auth;
  late final StreamSubscription<bool> _editionSub;
  StreamSubscription<Object?>? _authSub;

  /// FLAG_SECURE was left on by a background lock; clear it on resume.
  bool _windowSecureLeftOn = false;

  /// The open database for the secure features, or null while locked.
  SecureStore get store => _store;

  Future<SecureStatus> _currentStatus() async {
    if (!_edition.state.hasSecureFeatures) return SecureStatus.unavailable;
    if (_store.isOpen) return SecureStatus.unlocked;
    if (await _auth.getAuthType() != AuthType.pin) return SecureStatus.needsPin;
    final bool exists;
    try {
      exists = await _store.exists();
    } on SecureStoreException {
      return SecureStatus.broken;
    }
    if (exists) {
      return state.status == SecureStatus.broken
          ? SecureStatus.broken
          : SecureStatus.locked;
    }
    return await _auth.pinLength() < PinPolicy.secureLength
        ? SecureStatus.pinTooShort
        : SecureStatus.notCreated;
  }

  Future<void> _onRefresh(
    SecureSessionRefresh event,
    Emitter<SecureSessionState> emit,
  ) async {
    // Losing the secure features while open (deactivation) closes the section.
    if (!_edition.state.hasSecureFeatures && _store.isOpen) {
      await _closeSection(keepWindowSecure: false);
    }
    emit(state.copyWith(status: await _currentStatus()));
  }

  Future<void> _onUnlock(
    SecureUnlockRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    if (state.busy) return;
    final status = await _currentStatus();
    if (status != SecureStatus.locked && status != SecureStatus.notCreated) {
      emit(state.copyWith(status: status));
      return;
    }
    emit(state.copyWith(status: status, busy: true, clearFailure: true));
    try {
      await _unlockOrCreate(event.pin, status, emit);
    } catch (_) {
      // Anything unforeseen (I/O, a platform error): never leave the section
      // half open, the window flag set, or the screen stuck on "busy".
      await _store.lock();
      await _store.setSecureWindow(false);
      emit(
        state.copyWith(
          status: status,
          busy: false,
          lastFailure: SecureFailure.failed,
          failureMessage: 'باز کردن بخش امن انجام نشد؛ دوباره تلاش کنید',
          failures: state.failures + 1,
        ),
      );
    }
  }

  Future<void> _unlockOrCreate(
    String pin,
    SecureStatus status,
    Emitter<SecureSessionState> emit,
  ) async {
    // The PIN first, through the shared budget — cheap, and throttled.
    if (!await _auth.validatePin(pin)) {
      final wait = await _auth.pinRetryAfter();
      emit(
        state.copyWith(
          busy: false,
          lastFailure: wait == null
              ? SecureFailure.wrongPin
              : SecureFailure.lockedOut,
          failureMessage: wait == null
              ? 'رمز عبور اشتباه است'
              : PinAttemptLimiter.lockoutMessage(wait),
          failures: state.failures + 1,
        ),
      );
      return;
    }

    try {
      // FLAG_SECURE before any secure content can reach the screen.
      await _store.setSecureWindow(true);
      if (status == SecureStatus.notCreated) {
        await _store.create(pin);
      } else {
        await _store.unlock(pin);
      }
      _windowSecureLeftOn = false;
      emit(
        state.copyWith(
          status: SecureStatus.unlocked,
          busy: false,
          clearFailure: true,
          failures: 0,
        ),
      );
    } on SecureStoreException catch (e) {
      await _store.setSecureWindow(false);
      // The app PIN was right, so a vault that still refuses it (or cannot be
      // read at all) is broken, not a mistyped PIN.
      final broken =
          e.failure == VaultFailure.wrongPin ||
          e.failure == VaultFailure.keyLost ||
          e.failure == VaultFailure.corrupt;
      emit(
        state.copyWith(
          status: broken ? SecureStatus.broken : status,
          busy: false,
          lastFailure: broken ? SecureFailure.broken : SecureFailure.failed,
          failureMessage: broken
              ? 'بخش امن قابل باز شدن نیست'
              : 'باز کردن بخش امن انجام نشد؛ دوباره تلاش کنید',
          failures: state.failures + 1,
        ),
      );
    }
  }

  Future<void> _onLock(
    SecureLockRequested event,
    Emitter<SecureSessionState> emit,
  ) async {
    if (!_store.isOpen) return;
    await _closeSection(keepWindowSecure: false);
    emit(state.copyWith(status: await _currentStatus(), clearFailure: true));
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
    emit(state.copyWith(status: await _currentStatus()));
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
    emit(SecureSessionState(status: await _currentStatus()));
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
    await _authSub?.cancel();
    if (_store.isOpen) await _store.lock();
    return super.close();
  }
}
