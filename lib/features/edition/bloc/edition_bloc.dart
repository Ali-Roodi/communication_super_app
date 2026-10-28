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

/// Checks [code] against this device and, on a match, activates: the
/// inter-organizational edition in the commercial build, the app itself in the
/// organization build.
class ActivateEdition extends EditionEvent {
  final String code;
  const ActivateEdition(this.code);
  @override
  List<Object?> get props => [code];
}

/// Drops back to the commercial edition. The stored code is forgotten, so the
/// same code (it does not change for a device) activates it again. Commercial
/// build only: an organization APK has nothing to fall back to.
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
  /// The edition the app is in right now: [AppEdition.organization] for an
  /// organization build — activated or not, see [activated] — and for the
  /// commercial build either [AppEdition.commercial] or, after activation,
  /// [AppEdition.interOrganization].
  final AppEdition edition;

  /// A stored activation code verified against this device. In the commercial
  /// build it is the same fact as [edition] being inter-organizational; in the
  /// organization build it is what lets the app open at all
  /// (`OrganizationActivationGate`).
  final bool activated;

  /// The code the user reads to the mentor. Null until loaded, or on a device
  /// with no identity — [deviceCodeUnavailable] tells those apart.
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
    this.activated = false,
    this.deviceCode,
    this.loaded = false,
    this.deviceCodeUnavailable = false,
    this.checking = false,
    this.lastFailure,
    this.failedAttempts = 0,
  });

  /// The editions that carry the secure features (lock icon, encrypted SMS,
  /// hidden phonebook). What later phases branch on. An organization APK that
  /// is not activated has none — the gate keeps it closed anyway; this keeps
  /// the secure section closed even behind the gate.
  bool get hasSecureFeatures => switch (edition) {
    AppEdition.commercial => false,
    AppEdition.interOrganization => true,
    AppEdition.organization => activated,
  };

  EditionState copyWith({
    AppEdition? edition,
    bool? activated,
    String? deviceCode,
    bool? loaded,
    bool? deviceCodeUnavailable,
    bool? checking,
    ActivationFailure? lastFailure,
    bool clearLastFailure = false,
    int? failedAttempts,
  }) => EditionState(
    edition: edition ?? this.edition,
    activated: activated ?? this.activated,
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
    activated,
    deviceCode,
    loaded,
    deviceCodeUnavailable,
    checking,
    lastFailure,
    failedAttempts,
  ];
}

// ── Bloc ────────────────────────────────────────────────────────────────────

/// The edition the running app is in, and whether it is activated.
///
/// The build decides between commercial and organization at compile time
/// ([AppEdition.current]); this bloc adds activation on top: commercial →
/// inter-organizational, and organization not-yet-usable → usable. Every
/// edition-dependent screen reads it.
class EditionBloc extends Bloc<EditionEvent, EditionState> {
  EditionBloc(this._repository, {AppEdition build = AppEdition.current})
    : _build = build,
      super(EditionState(edition: build)) {
    on<LoadEdition>(_onLoad);
    on<ActivateEdition>(_onActivate);
    on<DeactivateInterOrganization>(_onDeactivate);
  }

  final ActivationRepository _repository;

  /// [AppEdition.current] outside tests.
  final AppEdition _build;

  bool get _isCommercialBuild => _build == AppEdition.commercial;

  /// The edition an activation (or its absence) leaves the app in.
  AppEdition _editionFor({required bool activated}) => _isCommercialBuild
      ? (activated ? AppEdition.interOrganization : AppEdition.commercial)
      : _build;

  Future<void> _onLoad(LoadEdition event, Emitter<EditionState> emit) async {
    final deviceCode = await _repository.deviceCode();
    final activated = deviceCode != null && await _repository.isActivated();
    emit(
      state.copyWith(
        edition: _editionFor(activated: activated),
        activated: activated,
        deviceCode: deviceCode,
        deviceCodeUnavailable: deviceCode == null,
        loaded: true,
      ),
    );
  }

  Future<void> _onActivate(
    ActivateEdition event,
    Emitter<EditionState> emit,
  ) async {
    if (state.checking || state.activated) return;
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
              edition: _editionFor(activated: true),
              activated: true,
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
    if (!_isCommercialBuild) return;
    await _repository.deactivate();
    emit(
      state.copyWith(
        edition: AppEdition.commercial,
        activated: false,
        clearLastFailure: true,
        failedAttempts: 0,
      ),
    );
  }
}
