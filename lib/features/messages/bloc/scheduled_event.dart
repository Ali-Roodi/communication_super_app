import 'package:equatable/equatable.dart';
import '../models/scheduled_message_model.dart';

abstract class ScheduledEvent extends Equatable {
  const ScheduledEvent();

  @override
  List<Object?> get props => [];
}

/// Load (or reload) all schedules.
class LoadScheduled extends ScheduledEvent {
  const LoadScheduled();
}

/// Create a new schedule, or update an existing one when [id] is non-null.
class SaveScheduled extends ScheduledEvent {
  final String? id;
  final String phoneNumber;
  final String? contactName;
  final String body;
  final DateTime scheduledAt;
  final ScheduleRepeat repeat;
  final int repeatEvery;
  final Set<int> weekdays;
  final JitterWindow jitter;
  final ScheduleEnd endType;
  final DateTime? endDate;
  final int? maxOccurrences;

  const SaveScheduled({
    this.id,
    required this.phoneNumber,
    this.contactName,
    required this.body,
    required this.scheduledAt,
    this.repeat = ScheduleRepeat.none,
    this.repeatEvery = 1,
    this.weekdays = const {},
    this.jitter = JitterWindow.none,
    this.endType = ScheduleEnd.never,
    this.endDate,
    this.maxOccurrences,
  });

  @override
  List<Object?> get props => [
    id,
    phoneNumber,
    contactName,
    body,
    scheduledAt,
    repeat,
    repeatEvery,
    weekdays,
    jitter,
    endType,
    endDate,
    maxOccurrences,
  ];
}

/// Mark a schedule cancelled (keeps the row for history).
class CancelScheduled extends ScheduledEvent {
  final String id;
  const CancelScheduled(this.id);

  @override
  List<Object?> get props => [id];
}

/// Delete a schedule row entirely.
class DeleteScheduled extends ScheduledEvent {
  final String id;
  const DeleteScheduled(this.id);

  @override
  List<Object?> get props => [id];
}

/// Send every schedule whose fire time has arrived (foreground delivery).
class DeliverDueScheduled extends ScheduledEvent {
  const DeliverDueScheduled();
}

/// Send a pending schedule immediately, without waiting for its time
/// («ارسال فوری»). Recurring schedules advance to their next occurrence as if
/// the send had happened on time.
class SendScheduledNow extends ScheduledEvent {
  final String id;
  const SendScheduledNow(this.id);

  @override
  List<Object?> get props => [id];
}
