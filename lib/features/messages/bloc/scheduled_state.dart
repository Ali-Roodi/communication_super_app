import 'package:equatable/equatable.dart';
import '../models/scheduled_message_model.dart';

abstract class ScheduledState extends Equatable {
  const ScheduledState();

  @override
  List<Object?> get props => [];
}

class ScheduledInitial extends ScheduledState {
  const ScheduledInitial();
}

class ScheduledLoading extends ScheduledState {
  const ScheduledLoading();
}

class ScheduledLoaded extends ScheduledState {
  final List<ScheduledMessage> items;

  const ScheduledLoaded(this.items);

  /// Upcoming (still-pending) schedules, soonest first.
  List<ScheduledMessage> get pending =>
      items.where((m) => m.status == ScheduleStatus.pending).toList();

  /// Completed / cancelled / failed schedules — the history section.
  List<ScheduledMessage> get history =>
      items.where((m) => m.status != ScheduleStatus.pending).toList();

  @override
  List<Object?> get props => [items];
}

class ScheduledError extends ScheduledState {
  final String message;
  const ScheduledError(this.message);

  @override
  List<Object?> get props => [message];
}
