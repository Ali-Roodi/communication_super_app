import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/edition/app_edition.dart';
import '../repositories/activation_repository.dart';

// ── Events ──────────────────────────────────────────────────────────────────

abstract class EditionEvent extends Equatable {
  const EditionEvent();
  @override
  List<Object?> get props => [];
}

/// Reads the edition this app is in. Dispatched once at startup.
class LoadEdition extends EditionEvent {
  const LoadEdition();
}

/// Checks [code] against this device and, on a match, unlocks the
/// inter-organizational edition.
class ActivateInterOrganization extends EditionEvent {
  final String code;
  const ActivateInterOrganization(this.code);
  @override
  List<Object?> get props => [code];
}

/// Drops back to the commercial edition. The stored code is forgotten, so the
/// same code (it does not change for a device) activates it again.
class DeactivateInterOrganization extends EditionEvent {
  const DeactivateInterOrganization();
}

// ── State ───────────────────────────────────────────────────────────────────

/// Why the last activation attempt did not unlock the edition.
enum ActivationFailure {
  /// The code is not this device's code.
  wrongCode,

  /// The code was right but could not be saved (secure storage refused).
  /// Distinct from [wrongCode] on purpose: telling the user a correct code is
  /// wrong sends them back to the mentor for a code that will not change.
  saveFailed,
}

class EditionState extends Equatable {
  /// The edition the app is in right now: [AppEdition.current] for an
  /// organization build, and for the commercial build either
  /// [AppEdition.commercial] or — after activation —
  /// [AppEdition.interOrganization].
  final AppEdition edition;

  /// The code the user reads to the mentor. Null until loaded, and in an
  /// organization build (which has nothing to activate) or on a device with no
  /// identity — [deviceCodeUnavailable] tells those apart.
  final String? deviceCode;

  final bool loaded;

  /// The device has no ANDROID_ID to derive a code from.
  final bool deviceCodeUnavailable;

  /// An activation check is running.
  final bool checking;

  /// Why the last attempt failed; null after a success or before any attempt.
  final ActivationFailure? lastFailure;

  /// Failed attempts so far. Part of the state so that a second identical
  /// failure in a row is a new state — a listener fires for it too.
  final int failedAttempts;

  const EditionState({
    required this.edition,
    this.deviceCode,
    this.loaded = false,
    this.deviceCodeUnavailable = false,
    this.checking = false,
    this.lastFailure,
    this.failedAttempts = 0,
  });

  /// The editions that carry the secure features (lock icon, encrypted SMS,
  /// hidden phonebook). What later phases branch on.
  bool get hasSecureFeatures => edition != AppEdition.commercial;

  EditionState copyWith({
    AppEdition? edition,
    String? deviceCode,
    bool? loaded,
    bool? deviceCodeUnavailable,
    bool? checking,
    ActivationFailure? lastFailure,
    bool clearLastFailure = false,
    int? failedAttempts,
  }) => EditionState(
    edition: edition ?? this.edition,
    deviceCode: deviceCode ?? this.deviceCode,
    loaded: loaded ?? this.loaded,
    deviceCodeUnavailable: deviceCodeUnavailable ?? this.deviceCodeUnavailable,
    checking: checking ?? this.checking,
    lastFailure: clearLastFailure ? null : (lastFailure ?? this.lastFailure),
    failedAttempts: failedAttempts ?? this.failedAttempts,
  );

  @override
  List<Object?> get props => [
    edition,
    deviceCode,
    loaded,
    deviceCodeUnavailable,
    checking,
    lastFailure,
    failedAttempts,
  ];
}

// ── Bloc ────────────────────────────────────────────────────────────────────

/// The edition the running app is in.
///
/// The build decides between commercial and organization at compile time
/// ([AppEdition.current]); this bloc adds the one runtime transition there is —
/// commercial → inter-organizational, by activation code — and is what every
/// edition-dependent screen reads.
class EditionBloc extends Bloc<EditionEvent, EditionState> {
  EditionBloc(this._repository)
    : super(const EditionState(edition: AppEdition.current)) {
    on<LoadEdition>(_onLoad);
    on<ActivateInterOrganization>(_onActivate);
    on<DeactivateInterOrganization>(_onDeactivate);
  }

  final ActivationRepository _repository;

  /// Activation exists only in the commercial build. The organization build
  /// is its edition by construction and never reads a device code.
  static const bool _canActivate = AppEdition.current == AppEdition.commercial;

  Future<void> _onLoad(LoadEdition event, Emitter<EditionState> emit) async {
    if (!_canActivate) {
      emit(state.copyWith(loaded: true));
      return;
    }
    final deviceCode = await _repository.deviceCode();
    final activated = deviceCode != null && await _repository.isActivated();
    emit(
      state.copyWith(
        edition: activated
            ? AppEdition.interOrganization
            : AppEdition.commercial,
        deviceCode: deviceCode,
        deviceCodeUnavailable: deviceCode == null,
        loaded: true,
      ),
    );
  }

  Future<void> _onActivate(
    ActivateInterOrganization event,
    Emitter<EditionState> emit,
  ) async {
    if (!_canActivate || state.checking) return;
    emit(state.copyWith(checking: true));
    ActivationFailure? failure;
    try {
      if (!await _repository.activate(event.code)) {
        failure = ActivationFailure.wrongCode;
      }
    } catch (_) {
      failure = ActivationFailure.saveFailed;
    }
    emit(
      failure == null
          ? state.copyWith(
              edition: AppEdition.interOrganization,
              checking: false,
              clearLastFailure: true,
              failedAttempts: 0,
            )
          : state.copyWith(
              checking: false,
              lastFailure: failure,
              failedAttempts: state.failedAttempts + 1,
            ),
    );
  }

  Future<void> _onDeactivate(
    DeactivateInterOrganization event,
    Emitter<EditionState> emit,
  ) async {
    if (!_canActivate) return;
    await _repository.deactivate();
    emit(
      state.copyWith(
        edition: AppEdition.commercial,
        clearLastFailure: true,
        failedAttempts: 0,
      ),
    );
  }
}
