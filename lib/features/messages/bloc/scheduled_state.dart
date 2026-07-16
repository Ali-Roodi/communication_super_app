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

  /// Upcoming schedules, soonest first. `sending` rows are included: they are
  /// mid-flight, not history, and dropping them would make the row blink out of
  /// the list for the duration of the send.
  List<ScheduledMessage> get pending => items.where(_isUpcoming).toList();

  /// Completed / cancelled / failed schedules — the history section.
  List<ScheduledMessage> get history =>
      items.where((m) => !_isUpcoming(m)).toList();

  /// Upcoming schedules addressed to [threadId] — the conversation screen's
  /// ghost bubbles.
  List<ScheduledMessage> pendingForThread(String threadId) =>
      items.where((m) => _isUpcoming(m) && m.threadId == threadId).toList()
        ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));

  static bool _isUpcoming(ScheduledMessage m) =>
      m.status == ScheduleStatus.pending || m.status == ScheduleStatus.sending;

  @override
  List<Object?> get props => [items];
}

class ScheduledError extends ScheduledState {
  final String message;
  const ScheduledError(this.message);

  @override
  List<Object?> get props => [message];
}
