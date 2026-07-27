import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../models/scheduled_message_model.dart';
import '../repositories/scheduled_message_repository.dart';
import '../services/scheduled_delivery_service.dart';
import '../services/native_scheduled_sms_service.dart';
import 'scheduled_event.dart';
import 'scheduled_state.dart';

/// Manages scheduled outgoing messages (زمان‌بندی ارسال).
///
/// **Delivery has two paths and one owner per message.** While the app is alive
/// a periodic tick fires [DeliverDueScheduled]; when it is dead the native
/// AlarmManager worker (`ScheduledSmsWorker`) does the same job. Both take an
/// atomic claim on the rows they are about to send
/// ([ScheduledMessageRepository.claimDue]), so a message is sent exactly once
/// even if both run at the same instant.
///
/// When the alarm fires while the engine *is* alive, the native receiver hands
/// the work back here (see [NativeScheduledSmsService.onDeliverDueRequested]) so
/// the send flows through `SmsService` and the conversation re-renders, rather
/// than being written straight to SQLite behind the BLoCs' backs.
///
/// A send that fails for a transient reason (no service, no SIM) is retried
/// with backoff and only marked [ScheduleStatus.failed] after
/// [ScheduledMessage.maxAttempts] attempts.
class ScheduledMessageBloc extends Bloc<ScheduledEvent, ScheduledState> {
  final ScheduledMessageRepository _repository;
  final ScheduledDeliveryService _delivery;
  final NativeScheduledSmsService _nativeScheduler;
  static const _uuid = Uuid();
  Timer? _timer;

  ScheduledMessageBloc({
    ScheduledMessageRepository? repository,
    ScheduledDeliveryService? deliveryService,
    NativeScheduledSmsService? nativeScheduler,
    bool autoDeliver = true,
    Duration deliverInterval = const Duration(seconds: 30),
  }) : _repository = repository ?? ScheduledMessageRepository(),
       _delivery =
           deliveryService ?? ScheduledDeliveryService(repository: repository),
       _nativeScheduler = nativeScheduler ?? NativeScheduledSmsService(),
       super(const ScheduledInitial()) {
    on<LoadScheduled>(_onLoad);
    on<SaveScheduled>(_onSave);
    on<CancelScheduled>(_onCancel);
    on<DeleteScheduled>(_onDelete);
    on<DeliverDueScheduled>(_onDeliverDue);
    on<SendScheduledNow>(_onSendNow);

    // When the native alarm fires while the app is alive it hands delivery back
    // to us instead of writing to SQLite behind the BLoCs' backs — otherwise the
    // chat would keep showing the scheduled ghost bubble after the send.
    _nativeScheduler.onDeliverDueRequested = _deliverFromNativeAlarm;
    _nativeScheduler.startListening();

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
    _nativeScheduler.onDeliverDueRequested = null;
    return super.close();
  }

  /// Runs a delivery sweep on behalf of the native alarm, then refreshes the UI
  /// and re-arms the alarm (via [LoadScheduled]). Awaited by the platform
  /// channel: the native side falls back to headless delivery if this throws.
  Future<void> _deliverFromNativeAlarm() async {
    await _delivery.deliverDue();
    if (!isClosed) add(const LoadScheduled());
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
    final report = await _delivery.deliverDue();

    // Always re-read the table, even when this sweep sent nothing: the row may
    // have been delivered by the *native* worker (cold start, or an alarm that
    // fired while the engine was detached), which writes straight to SQLite. Our
    // cached state would otherwise keep a completed schedule alive as a ghost
    // bubble until the app restarted. ScheduledLoaded is value-equal, so an
    // unchanged table emits nothing.
    await _emitLoaded(emit);

    if (!report.changedAnything) return;
    // Delivering changed the earliest-pending time; re-arm the native alarm.
    await _nativeScheduler.reschedule();
  }

  /// «ارسال فوری» — pull the fire time to now, then deliver in the same turn so
  /// the user sees the bubble move without waiting for the periodic tick.
  Future<void> _onSendNow(
    SendScheduledNow event,
    Emitter<ScheduledState> emit,
  ) async {
    try {
      final msg = await _repository.getById(event.id);
      if (msg == null || msg.status != ScheduleStatus.pending) return;
      await _repository.reschedule(event.id, DateTime.now());
      // force: «ارسال فوری» must ignore the jitter window it would otherwise
      // wait out.
      await _delivery.deliverDue(force: {event.id});
      await _emitLoaded(emit);
      await _nativeScheduler.reschedule();
    } catch (e) {
      emit(ScheduledError(e.toString()));
    }
  }
}
