import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart'
    show KeyBankLockedException;
import 'package:communication_super_app/features/secure/services/hidden_bridge.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';

import '../repositories/hidden_contacts_repository.dart';
import '../services/hidden_history_mover.dart';
import '../services/sealed_inbox.dart';
import '../services/sealing_key.dart';

// ── Events ───────────────────────────────────────────────────────────────────

sealed class HiddenEvent {
  const HiddenEvent();
}

class _SectionChanged extends HiddenEvent {
  const _SectionChanged(this.unlocked);
  final bool unlocked;
}

/// The system call log changed — a sweep may have sealed a hidden call.
class _CallLogChanged extends HiddenEvent {
  const _CallLogChanged();
}

class HiddenRefresh extends HiddenEvent {
  const HiddenRefresh();
}

/// Creates or updates a hidden contact. [numbers] as typed; they are made
/// canonical here.
class HiddenSaveContact extends HiddenEvent {
  const HiddenSaveContact({
    required this.id,
    required this.name,
    required this.numbers,
    this.note,
  });
  final String id;
  final String name;
  final List<String> numbers;
  final String? note;
}

class HiddenDeleteContact extends HiddenEvent {
  const HiddenDeleteContact(this.id);
  final String id;
}

class HiddenDeleteCalls extends HiddenEvent {
  const HiddenDeleteCalls(this.ids);
  final List<int> ids;
}

class HiddenClearCalls extends HiddenEvent {
  const HiddenClearCalls();
}

// ── State ────────────────────────────────────────────────────────────────────

enum HiddenStatus { locked, loading, ready }

/// Why a save was refused.
enum HiddenSaveError { noName, noNumber, badNumber, numberTaken }

class HiddenState extends Equatable {
  const HiddenState({
    this.status = HiddenStatus.locked,
    this.contacts = const [],
    this.calls = const [],
    this.savedSeq = 0,
    this.savedId,
    this.error,
    this.errorDetail,
    this.errorSeq = 0,
  });

  final HiddenStatus status;
  final List<HiddenContact> contacts;
  final List<HiddenCall> calls;

  /// Bumped when a save went through ([savedId] is the contact).
  final int savedSeq;
  final String? savedId;

  /// Bumped when a save was refused; [errorDetail] names the other contact
  /// for [HiddenSaveError.numberTaken].
  final HiddenSaveError? error;
  final String? errorDetail;
  final int errorSeq;

  /// Number → name, for the call history.
  Map<String, String> get names => {
    for (final c in contacts.reversed)
      for (final n in c.numbers) n.phone: c.name,
  };

  HiddenContact? contactById(String id) =>
      contacts.where((c) => c.id == id).firstOrNull;

  HiddenState copyWith({
    HiddenStatus? status,
    List<HiddenContact>? contacts,
    List<HiddenCall>? calls,
    String? savedId,
    HiddenSaveError? error,
    String? errorDetail,
  }) => HiddenState(
    status: status ?? this.status,
    contacts: contacts ?? this.contacts,
    calls: calls ?? this.calls,
    savedSeq: savedId == null ? savedSeq : savedSeq + 1,
    savedId: savedId ?? this.savedId,
    error: error ?? this.error,
    errorDetail: error == null ? this.errorDetail : errorDetail,
    errorSeq: error == null ? errorSeq : errorSeq + 1,
  );

  @override
  List<Object?> get props => [
    status,
    contacts,
    calls,
    savedSeq,
    savedId,
    error,
    errorDetail,
    errorSeq,
  ];
}

/// Hands a newly hidden number's SMS history to the encrypted-messages side
/// and completes once it is stored there (true) — only then is the original
/// deleted.
typedef HistoryImporter =
    Future<bool> Function(String phone, String name, List<MovedSms> history);

typedef PeerRenamer = void Function(List<String> phones, String name);

// ── Bloc ─────────────────────────────────────────────────────────────────────

/// «دفترچه مخفی» and «تماس‌های مخفی» (phase G, matrix rows 11 and 35).
///
/// While the section is open it keeps Kotlin informed — the hidden set as
/// tags, the names in memory, the sealing key — and drains the calls Kotlin
/// sealed. When it locks, the names are dropped from Kotlin and the state
/// empties, exactly like the key bank and the encrypted messages.
class HiddenBloc extends Bloc<HiddenEvent, HiddenState> {
  HiddenBloc({
    required SecureSessionBloc session,
    HiddenContactsRepository? repository,
    HiddenBridge bridge = const HiddenBridge(),
    SealingKey? sealingKey,
    SealedInbox? sealed,
    HiddenHistoryMover? mover,
    SmsCryptoService crypto = const SmsCryptoService(),
    HistoryImporter? importHistory,
    PeerRenamer? renamePeer,
    void Function(List<String> phones)? onHistoryMoved,
    Stream<void>? callLogChanges,
    int Function()? clock,
  }) : _repo = repository ?? HiddenContactsRepository(),
       _bridge = bridge,
       _key = sealingKey ?? SealingKey(bridge: bridge),
       _sealed = sealed ?? SealedInbox(crypto: crypto),
       _mover = mover ?? HiddenHistoryMover(),
       _crypto = crypto,
       _importHistory = importHistory,
       _renamePeer = renamePeer,
       _onHistoryMoved = onHistoryMoved,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       super(const HiddenState()) {
    on<_SectionChanged>(_onSection);
    on<_CallLogChanged>((e, emit) async {
      if (_open && await _drainCalls() > 0) await _reload(emit);
    });
    on<HiddenRefresh>((e, emit) async {
      if (!_open) return;
      await _drainCalls();
      await _reload(emit);
    });
    on<HiddenSaveContact>(_onSave);
    on<HiddenDeleteContact>(_onDelete);
    on<HiddenDeleteCalls>((e, emit) async {
      await _guard(() => _repo.deleteCalls(e.ids));
      await _reload(emit);
    });
    on<HiddenClearCalls>((e, emit) async {
      await _guard(_repo.clearCalls);
      await _reload(emit);
    });

    _subs = [
      session.stream
          .map((s) => s.isUnlocked)
          .distinct()
          .listen((u) => add(_SectionChanged(u))),
      if (callLogChanges != null)
        callLogChanges.listen((_) => add(const _CallLogChanged())),
    ];
    if (session.state.isUnlocked) add(const _SectionChanged(true));
  }

  final HiddenContactsRepository _repo;
  final HiddenBridge _bridge;
  final SealingKey _key;
  final SealedInbox _sealed;
  final HiddenHistoryMover _mover;
  final SmsCryptoService _crypto;
  final HistoryImporter? _importHistory;
  final PeerRenamer? _renamePeer;
  final void Function(List<String> phones)? _onHistoryMoved;
  final int Function() _clock;
  late final List<StreamSubscription<Object?>> _subs;

  bool get _open => state.status != HiddenStatus.locked;

  Future<void> _guard(Future<void> Function() call) async {
    if (!_open) return;
    try {
      await call();
    } on KeyBankLockedException {
      // Locked meanwhile: _SectionChanged(false) resets the state.
    } catch (e) {
      debugPrint('Hidden phonebook: ${e.runtimeType}');
    }
  }

  Future<void> _onSection(_SectionChanged e, Emitter<HiddenState> emit) async {
    if (!e.unlocked) {
      await _bridge.clearNames();
      emit(const HiddenState());
      return;
    }
    emit(state.copyWith(status: HiddenStatus.loading));
    try {
      await _key.ensure();
      await _push();
      // A call that ended while the app was away and was not swept yet.
      await _bridge.sweep();
      await _drainCalls();
    } on KeyBankLockedException {
      emit(const HiddenState());
      return;
    } catch (err) {
      debugPrint('Opening the hidden phonebook: ${err.runtimeType}');
    }
    await _reload(emit);
  }

  /// Tells Kotlin the hidden set (a change sweeps the whole call log) and,
  /// while open, the names.
  Future<void> _push() async {
    await _bridge.setNumbers(await _repo.allNumbers());
    await _bridge.setNames(await _repo.names());
  }

  /// Calls Kotlin sealed, into `hc_calls`. Returns how many were new.
  Future<int> _drainCalls() async {
    try {
      final secret = await _key.secret();
      if (secret == null) return 0;
      final entries = await _sealed.open(SealedInbox.kindCall, secret);
      if (entries.isEmpty) return 0;
      final records = <HiddenCallRecord>[];
      for (final e in entries) {
        final r = e.record;
        final number = r?['number'];
        final type = r?['type'];
        final date = r?['date'];
        if (number is! String || type is! int || date is! int) continue;
        records.add(
          HiddenCallRecord(
            phone: await _crypto.canonicalPhone(number) ?? number,
            callType: type,
            timestamp: date,
            duration: r?['duration'] as int?,
            account: r?['account'] as String?,
          ),
        );
      }
      final added = await _repo.addCalls(records);
      await _sealed.remove(entries.map((e) => e.id));
      return added;
    } on KeyBankLockedException {
      return 0;
    } catch (err) {
      debugPrint('Draining hidden calls failed: ${err.runtimeType}');
      return 0;
    }
  }

  Future<void> _reload(Emitter<HiddenState> emit) async {
    try {
      emit(
        state.copyWith(
          status: HiddenStatus.ready,
          contacts: await _repo.contacts(),
          calls: await _repo.calls(),
        ),
      );
    } on KeyBankLockedException {
      emit(const HiddenState());
    }
  }

  Future<void> _onSave(HiddenSaveContact e, Emitter<HiddenState> emit) async {
    if (!_open) return;
    final name = e.name.trim();
    if (name.isEmpty) {
      emit(state.copyWith(error: HiddenSaveError.noName));
      return;
    }
    final numbers = <String>[];
    for (final raw
        in e.numbers.map((n) => n.trim()).where((n) => n.isNotEmpty)) {
      final phone = await _crypto.canonicalPhone(raw);
      if (phone == null) {
        emit(
          state.copyWith(error: HiddenSaveError.badNumber, errorDetail: raw),
        );
        return;
      }
      if (!numbers.contains(phone)) numbers.add(phone);
    }
    if (numbers.isEmpty) {
      emit(state.copyWith(error: HiddenSaveError.noNumber));
      return;
    }
    try {
      for (final phone in numbers) {
        final owner = await _repo.ownerOf(phone, exceptId: e.id);
        if (owner != null) {
          emit(
            state.copyWith(
              error: HiddenSaveError.numberTaken,
              errorDetail: owner.name,
            ),
          );
          return;
        }
      }
      final before = (await _repo.allNumbers()).toSet();
      await _repo.save(
        HiddenContact(
          id: e.id,
          name: name,
          note: (e.note?.trim().isEmpty ?? true) ? null : e.note!.trim(),
          numbers: [for (final p in numbers) HiddenNumber(phone: p)],
        ),
        _clock(),
      );
      // Tags first: from here on nothing new with these numbers reaches the
      // system logs, and Kotlin has swept the calls already there.
      await _push();
      await _drainCalls();
      _renamePeer?.call(numbers, name);
      final added = numbers.where((p) => !before.contains(p)).toList();
      if (added.isNotEmpty) await _moveHistory(added, name);
    } on KeyBankLockedException {
      emit(const HiddenState());
      return;
    }
    // The list first, then "saved": the screen that pops on it lands on a
    // list that already has the contact.
    await _reload(emit);
    if (_open) emit(state.copyWith(savedId: e.id));
  }

  /// The SMS and mirrored calls of numbers that just became hidden.
  Future<void> _moveHistory(List<String> phones, String name) async {
    for (final phone in phones) {
      try {
        final history = await _mover.smsHistory(phone);
        var stored = history.isEmpty;
        if (!stored) {
          stored = await _importHistory?.call(phone, name, history) ?? false;
        }
        // Never delete what the section did not take.
        if (stored) await _mover.purgeSms(phone);
        await _mover.purgeCalls(phone);
      } catch (err) {
        debugPrint(
          'Moving a hidden number\'s history failed: ${err.runtimeType}',
        );
      }
    }
    _onHistoryMoved?.call(phones);
  }

  Future<void> _onDelete(
    HiddenDeleteContact e,
    Emitter<HiddenState> emit,
  ) async {
    await _guard(() async {
      await _repo.delete(e.id);
      await _push();
    });
    await _reload(emit);
  }

  @override
  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    return super.close();
  }
}
