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

/// The 16-character code read out to the user, and the password of their key
/// file: builds the key in the app, the same one the file holds.
class KeyBankImportCode extends KeyBankEvent {
  const KeyBankImportCode(this.code, this.password);
  final String code;
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

  /// The key was built from a code.
  built,

  /// It replaced the key held from the same authority.
  replaced,
  alreadyImported,
  older,
  wrongPassword,

  /// The code or its password is wrong: nothing was built.
  wrongCode,
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

  /// An import is running (Argon2id: a second or two).
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
/// ([TrustAnchors]), and this phone's own key, from the file the authority's
/// panel issues or built from the code it shows. Nothing about anybody else.
class KeyBankBloc extends Bloc<KeyBankEvent, KeyBankState> {
  KeyBankBloc({
    required SecureSessionBloc session,
    KeyBankRepository? repository,
    SmsCryptoService crypto = const SmsCryptoService(),
    List<Uint8List> Function()? anchors,
    List<Uint8List> Function()? signers,
  }) : _repository = repository ?? KeyBankRepository(),
       _crypto = crypto,
       _anchors = anchors ?? (() => TrustAnchors.all),
       _signers = signers ?? (() => TrustAnchors.signers),
       super(const KeyBankState()) {
    on<_SectionChanged>(_onSectionChanged);
    on<KeyBankRefresh>(_onRefresh);
    on<KeyBankImportFile>(_onImportFile);
    on<KeyBankImportCode>(_onImportCode);
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
  final List<Uint8List> Function() _signers;
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

  Future<void> _onImportFile(KeyBankImportFile e, Emitter<KeyBankState> emit) =>
      _import(
        emit,
        () => _crypto.openKeyFile(
          file: e.file,
          password: e.password,
          anchors: _anchors(),
        ),
        added: KeyBankNotice.imported,
        wrong: KeyBankNotice.wrongPassword,
      );

  Future<void> _onImportCode(KeyBankImportCode e, Emitter<KeyBankState> emit) =>
      _import(
        emit,
        () => _crypto.keyFromCode(
          code: e.code,
          password: e.password,
          anchors: _anchors(),
          signers: _signers(),
        ),
        added: KeyBankNotice.built,
        wrong: KeyBankNotice.wrongCode,
      );

  /// Both routes from here on are one: what [open] returns is stored the same
  /// way, so a key cannot differ by how it got here.
  Future<void> _import(
    Emitter<KeyBankState> emit,
    Future<OpenedKeyFile> Function() open, {
    required KeyBankNotice added,
    required KeyBankNotice wrong,
  }) async {
    if (!_open || state.busy) return;
    emit(state.copyWith(busy: true));
    try {
      final outcome = await _repository.importKeyFile(await open());
      await _reload(
        emit,
        notice: switch (outcome) {
          KeyImportOutcome.added => added,
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
            SmsCryptoFailure.wrongPassword => wrong,
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
      debugPrint('Key import failed: ${x.runtimeType}');
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
