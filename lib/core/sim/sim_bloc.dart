import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'sim_card.dart';
import 'sim_service.dart';

/// Events

sealed class SimEvent extends Equatable {
  const SimEvent();
  @override
  List<Object?> get props => const [];
}

/// Reads the roster from the platform. Dispatched at startup and again after
/// the permission gate, because `SubscriptionManager` answers nothing until
/// READ_PHONE_STATE is granted.
class LoadSims extends SimEvent {
  const LoadSims();
}

/// Internal: the native roster changed under us (SIM inserted or removed).
class _SimsChanged extends SimEvent {
  const _SimsChanged(this.sims);
  final List<SimCard> sims;
  @override
  List<Object?> get props => [sims];
}

/// State

class SimState extends Equatable {
  const SimState({
    this.sims = const [],
    this.defaults = const SimDefaults.unknown(),
  });

  final List<SimCard> sims;
  final SimDefaults defaults;

  /// Whether the SIM affordances (chips, pickers, badges) should exist at all.
  bool get isMultiSim => sims.length > 1;

  @override
  List<Object?> get props => [sims, defaults];
}

/// Bloc
///
/// Deliberately roster-only. *Which* SIM a particular send or call uses is not
/// global state — it is a property of a conversation (remembered per thread,
/// Google Messages) or of one dial (asked per call, Google Phone) — so putting
/// a "selected SIM" here would make two conversations fight over one field.
class SimBloc extends Bloc<SimEvent, SimState> {
  SimBloc() : super(const SimState()) {
    on<LoadSims>(_onLoad);
    on<_SimsChanged>(_onChanged);

    SimService.instance.initialize();
    _sub = SimService.instance.onChanged.listen(
      (sims) => add(_SimsChanged(sims)),
    );
  }

  StreamSubscription<List<SimCard>>? _sub;

  Future<void> _onLoad(LoadSims event, Emitter<SimState> emit) async {
    final sims = await SimService.instance.load();
    emit(SimState(sims: sims, defaults: SimService.defaults));
  }

  void _onChanged(_SimsChanged event, Emitter<SimState> emit) {
    emit(SimState(sims: event.sims, defaults: SimService.defaults));
  }

  @override
  Future<void> close() {
    _sub?.cancel();
    return super.close();
  }
}
