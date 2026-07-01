import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../models/scheduled_message_model.dart';
import '../repositories/scheduled_message_repository.dart';
import '../services/sms_service.dart';
import '../services/native_scheduled_sms_service.dart';
import 'scheduled_event.dart';
import 'scheduled_state.dart';

/// Manages scheduled outgoing messages (زمان‌بندی ارسال).
///
/// **Delivery is PHASE 1 (foreground only):** while the app is running, a
/// periodic tick (and app-open) fires [DeliverDueScheduled], which sends every
/// schedule whose time has arrived via [SmsService]. True background delivery
/// when the app is closed needs a native AlarmManager/WorkManager + a headless
/// SMS path — deliberately deferred (see KNOWN_ISSUES / figma-sync notes).
class ScheduledMessageBloc extends Bloc<ScheduledEvent, ScheduledState> {
  final ScheduledMessageRepository _repository;
  final SmsService _smsService;
  final NativeScheduledSmsService _nativeScheduler;
  static const _uuid = Uuid();
  Timer? _timer;

  ScheduledMessageBloc({
    ScheduledMessageRepository? repository,
    SmsService? smsService,
    NativeScheduledSmsService? nativeScheduler,
    bool autoDeliver = true,
    Duration deliverInterval = const Duration(seconds: 30),
  }) : _repository = repository ?? ScheduledMessageRepository(),
       _smsService = smsService ?? SmsService(),
       _nativeScheduler = nativeScheduler ?? NativeScheduledSmsService(),
       super(const ScheduledInitial()) {
    on<LoadScheduled>(_onLoad);
    on<SaveScheduled>(_onSave);
    on<CancelScheduled>(_onCancel);
    on<DeleteScheduled>(_onDelete);
    on<DeliverDueScheduled>(_onDeliverDue);

    if (autoDeliver) {
      add(const DeliverDueScheduled());
      _timer = Timer.periodic(
        deliverInterval,
        (_) => add(const DeliverDueScheduled()),
      );
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }

  Future<void> _onLoad(
    LoadScheduled event,
    Emitter<ScheduledState> emit,
  ) async {
    if (state is! ScheduledLoaded) emit(const ScheduledLoading());
    await _emitLoaded(emit);
    // Arm the native alarm on app start for whatever is already pending.
    await _nativeScheduler.reschedule();
  }

  Future<void> _emitLoaded(Emitter<ScheduledState> emit) async {
    try {
      emit(ScheduledLoaded(await _repository.getAll()));
    } catch (e) {
      emit(ScheduledError(e.toString()));
    }
  }

  Future<void> _onSave(
    SaveScheduled event,
    Emitter<ScheduledState> emit,
  ) async {
    try {
      final body = event.body.trim();
      final phone = event.phoneNumber.trim();
      if (body.isEmpty || phone.isEmpty) return;
      await _repository.upsert(
        ScheduledMessage(
          id: event.id ?? _uuid.v4(),
          phoneNumber: phone,
          contactName: event.contactName,
          body: body,
          scheduledAt: event.scheduledAt,
          repeat: event.repeat,
          repeatEvery: event.repeatEvery,
          weekdays: event.weekdays,
          jitter: event.jitter,
          endType: event.endType,
          endDate: event.endDate,
          maxOccurrences: event.maxOccurrences,
          status: ScheduleStatus.pending,
          createdAt: DateTime.now(),
        ),
      );
      await _emitLoaded(emit);
      await _nativeScheduler.reschedule();
    } catch (e) {
      emit(ScheduledError(e.toString()));
    }
  }

  Future<void> _onCancel(
    CancelScheduled event,
    Emitter<ScheduledState> emit,
  ) async {
    try {
      await _repository.cancel(event.id);
      await _emitLoaded(emit);
      await _nativeScheduler.reschedule();
    } catch (e) {
      emit(ScheduledError(e.toString()));
    }
  }

  Future<void> _onDelete(
    DeleteScheduled event,
    Emitter<ScheduledState> emit,
  ) async {
    try {
      await _repository.delete(event.id);
      await _emitLoaded(emit);
      await _nativeScheduler.reschedule();
    } catch (e) {
      emit(ScheduledError(e.toString()));
    }
  }

  Future<void> _onDeliverDue(
    DeliverDueScheduled event,
    Emitter<ScheduledState> emit,
  ) async {
    try {
      final due = await _repository.getDue(DateTime.now());
      if (due.isEmpty) return;
      for (final msg in due) {
        try {
          final result = await _smsService.sendSms(msg.phoneNumber, msg.body);
          await _repository.upsert(
            result.success
                ? msg.advanceAfterSend()
                : msg.copyWith(status: ScheduleStatus.failed),
          );
        } catch (_) {
          await _repository.upsert(msg.copyWith(status: ScheduleStatus.failed));
        }
      }
      await _emitLoaded(emit);
      // Delivering changed the earliest-pending time; re-arm the native alarm.
      await _nativeScheduler.reschedule();
    } catch (e) {
      emit(ScheduledError(e.toString()));
    }
  }
}
