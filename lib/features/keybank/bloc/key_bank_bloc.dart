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

/// An update file (`update.hku`) the user picked: the newest directory of an
/// organization this phone already belongs to. No password.
class KeyBankImportUpdate extends KeyBankEvent {
  const KeyBankImportUpdate(this.file);
  final Uint8List file;
}

class KeyBankAddGroup extends KeyBankEvent {
  const KeyBankAddGroup(this.name, this.passphrase);
  final String name;
  final String passphrase;
}

class KeyBankRemoveDirectory extends KeyBankEvent {
  const KeyBankRemoveDirectory(this.id);
  final String id;
}

class KeyBankRemoveGroup extends KeyBankEvent {
  const KeyBankRemoveGroup(this.id);
  final String id;
}

class KeyBankAddOwnNumber extends KeyBankEvent {
  const KeyBankAddOwnNumber(this.phone);
  final String phone;
}

class KeyBankRemoveOwnNumber extends KeyBankEvent {
  const KeyBankRemoveOwnNumber(this.phone);
  final String phone;
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
  updated,
  ownKeyAdded,
  alreadyImported,
  older,
  wrongPassword,
  notAKeyFile,
  untrusted,
  badSignature,
  badBundle,

  /// An update file for an organization this phone has no key file of.
  updateNotForThisPhone,

  /// The update was imported, but it no longer lists this phone's key: the
  /// authority gave this member a new one, which only their own file has.
  ownKeyRetired,
  groupAdded,
  groupExists,
  numberAdded,
  numberExists,
  notANumber,
  failed,
}

class KeyBankState extends Equatable {
  const KeyBankState({
    this.status = KeyBankStatus.locked,
    this.snapshot = const KeyBankSnapshot(),
    this.busy = false,
    this.notice,
    this.noticeSeq = 0,
    this.lastGroupId,
  });

  final KeyBankStatus status;

  /// Public data only — see [KeyBankSnapshot].
  final KeyBankSnapshot snapshot;

  /// An import or a group derivation is running (Argon2id: about a second).
  final bool busy;
  final KeyBankNotice? notice;

  /// Bumped with every notice, so the same notice twice is two states.
  final int noticeSeq;

  /// The id of the group just added — shown so members can compare codes.
  final String? lastGroupId;

  KeyBankState copyWith({
    KeyBankStatus? status,
    KeyBankSnapshot? snapshot,
    bool? busy,
    KeyBankNotice? notice,
    String? lastGroupId,
  }) => KeyBankState(
    status: status ?? this.status,
    snapshot: snapshot ?? this.snapshot,
    busy: busy ?? this.busy,
    notice: notice ?? this.notice,
    noticeSeq: notice == null ? noticeSeq : noticeSeq + 1,
    lastGroupId: lastGroupId ?? this.lastGroupId,
  );

  @override
  List<Object?> get props => [
    status,
    snapshot,
    busy,
    notice,
    noticeSeq,
    lastGroupId,
  ];
}

// ── Bloc ─────────────────────────────────────────────────────────────────────

/// «بانک کلید»: the keys encrypted SMS is sent under. Lives inside the
/// secure section — it loads when the section opens and drops everything
/// when it closes, so a locked phone holds no key-bank data in memory.
///
/// Three sources (owner's decisions, 1405/07/05; see `editions.md`):
/// - the authority's public key, hardcoded ([TrustAnchors]);
/// - key files the authority's tool issues, imported here;
/// - passphrase groups, derived here.
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
    on<KeyBankImportUpdate>(_onImportUpdate);
    on<KeyBankAddGroup>(_onAddGroup);
    on<KeyBankRemoveDirectory>(
      (e, emit) => _mutate(emit, () => _repository.removeDirectory(e.id)),
    );
    on<KeyBankRemoveGroup>(
      (e, emit) => _mutate(emit, () => _repository.removeGroup(e.id)),
    );
    on<KeyBankAddOwnNumber>(_onAddOwnNumber);
    on<KeyBankRemoveOwnNumber>(
      (e, emit) => _mutate(emit, () => _repository.removeOwnNumber(e.phone)),
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
          KeyImportOutcome.updated => KeyBankNotice.updated,
          KeyImportOutcome.ownKeyAdded => KeyBankNotice.ownKeyAdded,
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
            SmsCryptoFailure.badSignature => KeyBankNotice.badSignature,
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

  Future<void> _onImportUpdate(
    KeyBankImportUpdate e,
    Emitter<KeyBankState> emit,
  ) async {
    if (!_open || state.busy) return;
    final directories = state.snapshot.directories;
    if (directories.isEmpty) {
      emit(state.copyWith(notice: KeyBankNotice.updateNotForThisPhone));
      return;
    }
    emit(state.copyWith(busy: true));
    try {
      final opened = await _crypto.openUpdateFile(
        file: e.file,
        directoryIds: [for (final d in directories) _unhex(d.id)],
        anchors: _anchors(),
      );
      final id = keyHex(opened.directory.directoryId);
      final hadOwnKey = directories.any((d) => d.id == id && d.hasOwnKey);
      final outcome = await _repository.importKeyFile(opened);
      final after = await _repository.snapshot();
      final hasOwnKey = after.directories.any((d) => d.id == id && d.hasOwnKey);
      await _reload(
        emit,
        notice: hadOwnKey && !hasOwnKey
            ? KeyBankNotice.ownKeyRetired
            : switch (outcome) {
                KeyImportOutcome.added => KeyBankNotice.imported,
                KeyImportOutcome.updated => KeyBankNotice.updated,
                KeyImportOutcome.ownKeyAdded => KeyBankNotice.ownKeyAdded,
                KeyImportOutcome.alreadyImported =>
                  KeyBankNotice.alreadyImported,
                KeyImportOutcome.older => KeyBankNotice.older,
              },
      );
    } on SmsCryptoException catch (x) {
      emit(
        state.copyWith(
          busy: false,
          notice: switch (x.failure) {
            SmsCryptoFailure.wrongPassword =>
              KeyBankNotice.updateNotForThisPhone,
            SmsCryptoFailure.notAKeyFile => KeyBankNotice.notAKeyFile,
            SmsCryptoFailure.untrusted => KeyBankNotice.untrusted,
            SmsCryptoFailure.badSignature => KeyBankNotice.badSignature,
            SmsCryptoFailure.badBundle => KeyBankNotice.badBundle,
            _ => KeyBankNotice.failed,
          },
        ),
      );
    } on KeyBankLockedException {
      emit(const KeyBankState());
    } catch (x) {
      debugPrint('Update file import failed: ${x.runtimeType}');
      emit(state.copyWith(busy: false, notice: KeyBankNotice.failed));
    }
  }

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  Future<void> _onAddGroup(
    KeyBankAddGroup e,
    Emitter<KeyBankState> emit,
  ) async {
    if (!_open || state.busy) return;
    emit(state.copyWith(busy: true));
    try {
      final derived = await _crypto.deriveGroup(
        name: e.name,
        passphrase: e.passphrase,
      );
      final added = await _repository.addGroup(
        groupId: derived.groupId,
        name: e.name,
        seed: derived.group,
      );
      emit(state.copyWith(lastGroupId: keyHex(derived.groupId)));
      await _reload(
        emit,
        notice: added ? KeyBankNotice.groupAdded : KeyBankNotice.groupExists,
      );
    } on KeyBankLockedException {
      emit(const KeyBankState());
    } catch (x) {
      debugPrint('Adding a group failed: ${x.runtimeType}');
      emit(state.copyWith(busy: false, notice: KeyBankNotice.failed));
    }
  }

  Future<void> _onAddOwnNumber(
    KeyBankAddOwnNumber e,
    Emitter<KeyBankState> emit,
  ) async {
    if (!_open) return;
    final phone = await _crypto.canonicalPhone(e.phone);
    if (phone == null) {
      emit(state.copyWith(notice: KeyBankNotice.notANumber));
      return;
    }
    try {
      final added = await _repository.addOwnNumber(phone);
      await _reload(
        emit,
        notice: added ? KeyBankNotice.numberAdded : KeyBankNotice.numberExists,
      );
    } on KeyBankLockedException {
      emit(const KeyBankState());
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
