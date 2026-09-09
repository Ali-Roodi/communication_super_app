import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/services/deep_link_service.dart';
import '../models/blocked_number_model.dart';
import '../repositories/blocked_numbers_repository.dart';

// ── Events ──────────────────────────────────────────────────────────────────

abstract class BlockedNumbersEvent extends Equatable {
  const BlockedNumbersEvent();
  @override
  List<Object?> get props => [];
}

class LoadBlocked extends BlockedNumbersEvent {
  const LoadBlocked();
}

/// Blocks a number, optionally reporting it as spam.
///
/// Google Messages/Phone treat these as one gesture with a checkbox
/// («مسدود کردن و گزارش هرزنامه»), not two separate menu items, which is why
/// [report] is a flag on this event rather than an event of its own.
class BlockNumber extends BlockedNumbersEvent {
  final String phoneNumber;
  final bool report;
  const BlockNumber(this.phoneNumber, {this.report = false});
  @override
  List<Object?> get props => [phoneNumber, report];
}

class UnblockNumber extends BlockedNumbersEvent {
  final String normalized;
  const UnblockNumber(this.normalized);
  @override
  List<Object?> get props => [normalized];
}

/// «این هرزنامه نیست» — drops the report but keeps the block.
class ClearSpamReport extends BlockedNumbersEvent {
  final String normalized;
  const ClearSpamReport(this.normalized);
  @override
  List<Object?> get props => [normalized];
}

// ── States ──────────────────────────────────────────────────────────────────

abstract class BlockedNumbersState extends Equatable {
  const BlockedNumbersState();

  /// Canonical keys currently blocked. Empty while loading or on error, so a
  /// caller can ask without type-checking the state first.
  Set<String> get blockedKeys => const {};

  bool isBlocked(String normalized) => blockedKeys.contains(normalized);

  @override
  List<Object?> get props => [];
}

class BlockedNumbersLoading extends BlockedNumbersState {
  const BlockedNumbersLoading();
}

class BlockedNumbersLoaded extends BlockedNumbersState {
  final List<BlockedNumberModel> numbers;
  const BlockedNumbersLoaded(this.numbers);

  /// Reported entries first, then the plain blocks — «هرزنامه» is what the user
  /// came to this list for.
  List<BlockedNumberModel> get spam =>
      numbers.where((n) => n.isSpam).toList(growable: false);

  List<BlockedNumberModel> get blockedOnly =>
      numbers.where((n) => !n.isSpam).toList(growable: false);

  @override
  Set<String> get blockedKeys => {for (final n in numbers) n.normalized};

  @override
  List<Object?> get props => [numbers];
}

class BlockedNumbersError extends BlockedNumbersState {
  final String message;
  const BlockedNumbersError(this.message);
  @override
  List<Object?> get props => [message];
}

// ── Bloc ────────────────────────────────────────────────────────────────────

/// Owns the blocked / reported list.
///
/// Blocking is enforced in four places that all read the same table — the live
/// SMS receiver, the cold-start receiver, `SmsDeliverReceiver` and
/// `CallInCallService` — so this bloc only has to keep the rows straight; it
/// never has to tell them anything. What it *does* have to get right is the key:
/// see [BlockedNumberModel.normalize].
class BlockedNumbersBloc
    extends Bloc<BlockedNumbersEvent, BlockedNumbersState> {
  final BlockedNumbersRepository _repository;

  BlockedNumbersBloc(this._repository) : super(const BlockedNumbersLoading()) {
    on<LoadBlocked>(_onLoad);
    on<BlockNumber>(_onBlock);
    on<UnblockNumber>(_onUnblock);
    on<ClearSpamReport>(_onClearReport);
  }

  Future<void> _onLoad(
    LoadBlocked event,
    Emitter<BlockedNumbersState> emit,
  ) async {
    // No `BlockedNumbersLoading` here when a list is already on screen: this
    // event also runs on every entry to the blocked list, and swapping a
    // painted list for a spinner is a flicker with nothing behind it.
    if (state is! BlockedNumbersLoaded) emit(const BlockedNumbersLoading());
    try {
      emit(BlockedNumbersLoaded(await _repository.getBlocked()));
    } catch (e) {
      emit(BlockedNumbersError(e.toString()));
    }
  }

  Future<void> _onBlock(
    BlockNumber event,
    Emitter<BlockedNumbersState> emit,
  ) async {
    // Rejected here rather than in the repository so a stray tap on a row with
    // no number never reaches the database at all.
    if (BlockedNumberModel.normalize(event.phoneNumber).isEmpty) return;
    try {
      final key = await _repository.block(
        event.phoneNumber,
        report: event.report,
      );
      if (key == null) return;
      // The sender's card leaves the shade with them. Without this the
      // conversation moved to «هرزنامه و مسدودشده» while its notification — and
      // so the launcher badge — stayed behind, on a thread there is no longer
      // any screen to open and clear it from.
      unawaited(DeepLinkService.instance.clearThreadNotifications(key));
      emit(BlockedNumbersLoaded(await _repository.getBlocked()));
    } catch (e) {
      emit(BlockedNumbersError(e.toString()));
    }
  }

  Future<void> _onUnblock(
    UnblockNumber event,
    Emitter<BlockedNumbersState> emit,
  ) async {
    try {
      await _repository.unblock(event.normalized);
      emit(BlockedNumbersLoaded(await _repository.getBlocked()));
    } catch (e) {
      emit(BlockedNumbersError(e.toString()));
    }
  }

  Future<void> _onClearReport(
    ClearSpamReport event,
    Emitter<BlockedNumbersState> emit,
  ) async {
    try {
      await _repository.clearReport(event.normalized);
      emit(BlockedNumbersLoaded(await _repository.getBlocked()));
    } catch (e) {
      emit(BlockedNumbersError(e.toString()));
    }
  }
}
