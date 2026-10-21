import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

import '../services/trust_anchors.dart';

// ── Events ───────────────────────────────────────────────────────────────────

sealed class KeyBankEvent {
  const KeyBankEvent();
}

/// The secure section opened or closed (fed from [SecureSessionBloc]).
class _SectionChanged extends KeyBankEvent {
  const _SectionChanged(this.unlocked);
  final bool unlocked;
}

class KeyBankRefresh extends KeyBankEvent {
  const KeyBankRefresh();
}

/// A key file the user picked, and the password they typed for it.
class KeyBankImportFile extends KeyBankEvent {
  const KeyBankImportFile(this.file, this.password);
  final Uint8List file;
  final String password;
}

/// Removes one of this phone's own keys (by its key id).
class KeyBankRemoveKey extends KeyBankEvent {
  const KeyBankRemoveKey(this.keyId);
  final String keyId;
}

// ── State ────────────────────────────────────────────────────────────────────

enum KeyBankStatus {
  /// The secure section is closed: nothing is loaded, nothing is in memory.
  locked,
  loading,
  ready,
}

/// The outcome of the last action, for a one-line confirmation or error.
enum KeyBankNotice {
  imported,

  /// It replaced the key held from the same authority.
  replaced,
  alreadyImported,
  older,
  wrongPassword,
  notAKeyFile,

  /// The certificate is not signed by an authority this build trusts.
  untrusted,
  badBundle,
  failed,
}

class KeyBankState extends Equatable {
  const KeyBankState({
    this.status = KeyBankStatus.locked,
    this.snapshot = const KeyBankSnapshot(),
    this.busy = false,
    this.notice,
    this.noticeSeq = 0,
  });

  final KeyBankStatus status;

  /// Public data only — see [KeyBankSnapshot].
  final KeyBankSnapshot snapshot;

  /// An import is running (Argon2id: about a second).
  final bool busy;
  final KeyBankNotice? notice;

  /// Bumped with every notice, so the same notice twice is two states.
  final int noticeSeq;

  KeyBankState copyWith({
    KeyBankStatus? status,
    KeyBankSnapshot? snapshot,
    bool? busy,
    KeyBankNotice? notice,
  }) => KeyBankState(
    status: status ?? this.status,
    snapshot: snapshot ?? this.snapshot,
    busy: busy ?? this.busy,
    notice: notice ?? this.notice,
    noticeSeq: notice == null ? noticeSeq : noticeSeq + 1,
  );

  @override
  List<Object?> get props => [status, snapshot, busy, notice, noticeSeq];
}

// ── Bloc ─────────────────────────────────────────────────────────────────────

/// «بانک کلید»: the keys encrypted SMS is sent under. Lives inside the
/// secure section — it loads when the section opens and drops everything
/// when it closes, so a locked phone holds no key-bank data in memory.
///
/// Its sources (see `editions.md`): the authority's public key, hardcoded
/// ([TrustAnchors]), and this phone's own key file, which the authority's
/// panel issues and is imported here. Nothing about anybody else.
class KeyBankBloc extends Bloc<KeyBankEvent, KeyBankState> {
  KeyBankBloc({
    required SecureSessionBloc session,
    KeyBankRepository? repository,
    SmsCryptoService crypto = const SmsCryptoService(),
    List<Uint8List> Function()? anchors,
  }) : _repository = repository ?? KeyBankRepository(),
       _crypto = crypto,
       _anchors = anchors ?? (() => TrustAnchors.all),
       super(const KeyBankState()) {
    on<_SectionChanged>(_onSectionChanged);
    on<KeyBankRefresh>(_onRefresh);
    on<KeyBankImportFile>(_onImport);
    on<KeyBankRemoveKey>(
      (e, emit) => _mutate(emit, () => _repository.removeKey(e.keyId)),
    );

    _sessionSub = session.stream
        .map((s) => s.isUnlocked)
        .distinct()
        .listen((unlocked) => add(_SectionChanged(unlocked)));
    if (session.state.isUnlocked) add(const _SectionChanged(true));
  }

  final KeyBankRepository _repository;
  final SmsCryptoService _crypto;
  final List<Uint8List> Function() _anchors;
  late final StreamSubscription<bool> _sessionSub;

  bool get _open => state.status != KeyBankStatus.locked;

  Future<void> _onSectionChanged(
    _SectionChanged e,
    Emitter<KeyBankState> emit,
  ) async {
    if (!e.unlocked) {
      emit(const KeyBankState());
      return;
    }
    emit(state.copyWith(status: KeyBankStatus.loading));
    await _reload(emit);
  }

  Future<void> _onRefresh(KeyBankRefresh e, Emitter<KeyBankState> emit) async {
    if (_open) await _reload(emit);
  }

  Future<void> _reload(
    Emitter<KeyBankState> emit, {
    KeyBankNotice? notice,
  }) async {
    try {
      final snapshot = await _repository.snapshot();
      emit(
        state.copyWith(
          status: KeyBankStatus.ready,
          snapshot: snapshot,
          busy: false,
          notice: notice,
        ),
      );
    } on KeyBankLockedException {
      emit(const KeyBankState());
    }
  }

  Future<void> _onImport(
    KeyBankImportFile e,
    Emitter<KeyBankState> emit,
  ) async {
    if (!_open || state.busy) return;
    emit(state.copyWith(busy: true));
    try {
      final opened = await _crypto.openKeyFile(
        file: e.file,
        password: e.password,
        anchors: _anchors(),
      );
      final outcome = await _repository.importKeyFile(opened);
      await _reload(
        emit,
        notice: switch (outcome) {
          KeyImportOutcome.added => KeyBankNotice.imported,
          KeyImportOutcome.replaced => KeyBankNotice.replaced,
          KeyImportOutcome.alreadyImported => KeyBankNotice.alreadyImported,
          KeyImportOutcome.older => KeyBankNotice.older,
        },
      );
    } on SmsCryptoException catch (x) {
      emit(
        state.copyWith(
          busy: false,
          notice: switch (x.failure) {
            SmsCryptoFailure.wrongPassword => KeyBankNotice.wrongPassword,
            SmsCryptoFailure.notAKeyFile => KeyBankNotice.notAKeyFile,
            SmsCryptoFailure.untrusted => KeyBankNotice.untrusted,
            SmsCryptoFailure.badBundle => KeyBankNotice.badBundle,
            _ => KeyBankNotice.failed,
          },
        ),
      );
    } on KeyBankLockedException {
      emit(const KeyBankState());
    } catch (x) {
      debugPrint('Key file import failed: ${x.runtimeType}');
      emit(state.copyWith(busy: false, notice: KeyBankNotice.failed));
    }
  }

  Future<void> _mutate(
    Emitter<KeyBankState> emit,
    Future<void> Function() change,
  ) async {
    if (!_open) return;
    try {
      await change();
      await _reload(emit);
    } on KeyBankLockedException {
      emit(const KeyBankState());
    }
  }

  @override
  Future<void> close() async {
    await _sessionSub.cancel();
    return super.close();
  }
}
