import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
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

class BlockNumber extends BlockedNumbersEvent {
  final String phoneNumber;
  const BlockNumber(this.phoneNumber);
  @override
  List<Object?> get props => [phoneNumber];
}

class UnblockNumber extends BlockedNumbersEvent {
  final String normalized;
  const UnblockNumber(this.normalized);
  @override
  List<Object?> get props => [normalized];
}

// ── States ──────────────────────────────────────────────────────────────────

abstract class BlockedNumbersState extends Equatable {
  const BlockedNumbersState();
  @override
  List<Object?> get props => [];
}

class BlockedNumbersLoading extends BlockedNumbersState {
  const BlockedNumbersLoading();
}

class BlockedNumbersLoaded extends BlockedNumbersState {
  final List<BlockedNumberModel> numbers;
  const BlockedNumbersLoaded(this.numbers);
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

class BlockedNumbersBloc
    extends Bloc<BlockedNumbersEvent, BlockedNumbersState> {
  final BlockedNumbersRepository _repository;
  static const _uuid = Uuid();

  BlockedNumbersBloc(this._repository) : super(const BlockedNumbersLoading()) {
    on<LoadBlocked>(_onLoad);
    on<BlockNumber>(_onBlock);
    on<UnblockNumber>(_onUnblock);
  }

  Future<void> _onLoad(
    LoadBlocked event,
    Emitter<BlockedNumbersState> emit,
  ) async {
    emit(const BlockedNumbersLoading());
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
    try {
      final normalized = BlockedNumberModel.normalize(event.phoneNumber);
      if (normalized.isEmpty) return;
      await _repository.block(
        BlockedNumberModel(
          id: _uuid.v4(),
          phoneNumber: event.phoneNumber,
          normalized: normalized,
          createdAt: DateTime.now(),
        ),
      );
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
}
