import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/scheduled_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_event.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_state.dart';
import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';
import 'package:communication_super_app/features/messages/repositories/scheduled_message_repository.dart';
import 'package:communication_super_app/features/messages/services/scheduled_delivery_service.dart';
import 'package:communication_super_app/features/messages/services/sms_service.dart';
import 'package:communication_super_app/features/messages/services/native_scheduled_sms_service.dart';

class _MockRepo extends Mock implements ScheduledMessageRepository {}

class _MockSms extends Mock implements SmsService {}

/// No-op so the bloc doesn't reach for the real platform channel in tests.
class _NoopNative implements NativeScheduledSmsService {
  @override
  Future<void> Function()? onDeliverDueRequested;
  @override
  void startListening() {}
  @override
  Future<void> reschedule() async {}
  @override
  Future<void> cancel() async {}
}

ScheduledMessage _due({
  String id = 's1',
  ScheduleRepeat repeat = ScheduleRepeat.none,
  int attemptCount = 0,
  JitterWindow jitter = JitterWindow.none,
  DateTime? at,
}) => ScheduledMessage(
  id: id,
  phoneNumber: '09120000000',
  body: 'سلام',
  scheduledAt: at ?? DateTime(2026, 1, 1, 9),
  repeat: repeat,
  attemptCount: attemptCount,
  jitter: jitter,
  createdAt: DateTime(2026, 1, 1),
);

/// A jittered schedule whose window has *not* elapsed yet: nominally due, but
/// its own offset puts the send a few minutes out.
ScheduledMessage _jitteredNotYetDue() {
  for (var minute = 0; minute < 60; minute++) {
    final row = _due(
      jitter: JitterWindow.sixtyMin,
      at: DateTime.now().subtract(Duration(minutes: minute)),
    );
    if (!row.isDueAt(DateTime.now())) return row;
  }
  throw StateError('no jittered row landed outside its window');
}

void main() {
  setUpAll(() {
    registerFallbackValue(_due());
    registerFallbackValue(DateTime(2026));
  });

  late _MockRepo repo;
  late _MockSms sms;

  setUp(() {
    repo = _MockRepo();
    sms = _MockSms();
    when(
      () => repo.getAll(status: any(named: 'status')),
    ).thenAnswer((_) async => const <ScheduledMessage>[]);
    when(() => repo.upsert(any())).thenAnswer((_) async {});
    when(() => repo.cancel(any())).thenAnswer((_) async {});
    when(() => repo.delete(any())).thenAnswer((_) async {});
    when(() => repo.reschedule(any(), any())).thenAnswer((_) async {});
    when(() => repo.getDue(any())).thenAnswer((_) async => const []);
    when(
      () => repo.claimDue(any(), any(), restrictTo: any(named: 'restrictTo')),
    ).thenAnswer((_) async => const []);
  });

  ScheduledMessageBloc build() => ScheduledMessageBloc(
    repository: repo,
    deliveryService: ScheduledDeliveryService(repository: repo, smsService: sms),
    nativeScheduler: _NoopNative(),
    autoDeliver: false,
  );

  /// Only the *first* claim yields rows: a second sweep must find nothing, which
  /// is what stops a message being sent twice.
  void claimYieldsOnce(List<ScheduledMessage> rows) {
    var first = true;
    // The deliverer reads the due rows first (jitter is decided per row) and
    // only then claims the ids it picked.
    when(() => repo.getDue(any())).thenAnswer((_) async => first ? rows : const []);
    when(
      () => repo.claimDue(any(), any(), restrictTo: any(named: 'restrictTo')),
    ).thenAnswer((_) async {
      if (!first) return const [];
      first = false;
      return rows;
    });
  }

  group('DeliverDueScheduled', () {
    blocTest<ScheduledMessageBloc, ScheduledState>(
      'sends each claimed message and completes a one-shot',
      setUp: () {
        claimYieldsOnce([_due()]);
        when(
          () => sms.sendSms(any(), any()),
        ).thenAnswer((_) async => const SmsServiceResult.ok());
      },
      build: build,
      act: (b) => b.add(const DeliverDueScheduled()),
      verify: (_) {
        verify(() => sms.sendSms('09120000000', 'سلام')).called(1);
        final captured =
            verify(() => repo.upsert(captureAny())).captured.last
                as ScheduledMessage;
        expect(captured.status, ScheduleStatus.completed);
        expect(captured.occurrenceCount, 1);
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'a transient failure schedules a retry instead of failing the message',
      setUp: () {
        claimYieldsOnce([_due()]);
        when(
          () => sms.sendSms(any(), any()),
        ).thenAnswer((_) async => const SmsServiceResult.fail('NO_SERVICE'));
      },
      build: build,
      act: (b) => b.add(const DeliverDueScheduled()),
      verify: (_) {
        final captured =
            verify(() => repo.upsert(captureAny())).captured.last
                as ScheduledMessage;
        expect(captured.status, ScheduleStatus.pending);
        expect(captured.attemptCount, 1);
        expect(captured.lastError, 'NO_SERVICE');
        expect(captured.nextAttemptAt, isNotNull);
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'the final attempt marks the message failed',
      setUp: () {
        claimYieldsOnce([
          _due(attemptCount: ScheduledMessage.maxAttempts - 1),
        ]);
        when(
          () => sms.sendSms(any(), any()),
        ).thenAnswer((_) async => const SmsServiceResult.fail('NO_SIM_CARD'));
      },
      build: build,
      act: (b) => b.add(const DeliverDueScheduled()),
      verify: (_) {
        final captured =
            verify(() => repo.upsert(captureAny())).captured.last
                as ScheduledMessage;
        expect(captured.status, ScheduleStatus.failed);
        expect(captured.lastError, 'NO_SIM_CARD');
        expect(captured.nextAttemptAt, isNull);
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'a recurring message stays pending with an advanced fire time',
      setUp: () {
        claimYieldsOnce([_due(repeat: ScheduleRepeat.daily)]);
        when(
          () => sms.sendSms(any(), any()),
        ).thenAnswer((_) async => const SmsServiceResult.ok());
      },
      build: build,
      act: (b) => b.add(const DeliverDueScheduled()),
      verify: (_) {
        final captured =
            verify(() => repo.upsert(captureAny())).captured.last
                as ScheduledMessage;
        expect(captured.status, ScheduleStatus.pending);
        expect(captured.scheduledAt.isAfter(DateTime.now()), isTrue);
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'sends nothing when the claim comes back empty',
      build: build,
      act: (b) => b.add(const DeliverDueScheduled()),
      verify: (_) => verifyNever(() => sms.sendSms(any(), any())),
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      're-reads the table even when this sweep sent nothing, so a schedule '
      'delivered by the native worker stops being shown as pending',
      setUp: () {
        // Claim yields nothing — the native worker already took the row and
        // completed it directly in SQLite.
        var reads = 0;
        when(() => repo.getAll(status: any(named: 'status'))).thenAnswer((
          _,
        ) async {
          reads++;
          return reads == 1
              ? [_due()]
              : [_due().copyWith(status: ScheduleStatus.completed)];
        });
      },
      build: build,
      act: (b) async {
        b.add(const LoadScheduled());
        await Future<void>.delayed(Duration.zero);
        b.add(const DeliverDueScheduled());
      },
      verify: (b) {
        final state = b.state as ScheduledLoaded;
        expect(state.pending, isEmpty);
        expect(state.history.single.status, ScheduleStatus.completed);
      },
    );
  });

  group('SendScheduledNow', () {
    blocTest<ScheduledMessageBloc, ScheduledState>(
      'pulls the fire time to now and delivers in the same turn',
      setUp: () {
        when(() => repo.getById('s1')).thenAnswer((_) async => _due());
        claimYieldsOnce([_due()]);
        when(
          () => sms.sendSms(any(), any()),
        ).thenAnswer((_) async => const SmsServiceResult.ok());
      },
      build: build,
      act: (b) => b.add(const SendScheduledNow('s1')),
      verify: (_) {
        verify(() => repo.reschedule('s1', any())).called(1);
        verify(() => sms.sendSms('09120000000', 'سلام')).called(1);
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'ignores a schedule that is no longer pending',
      setUp: () {
        when(() => repo.getById('s1')).thenAnswer(
          (_) async => _due().copyWith(status: ScheduleStatus.completed),
        );
      },
      build: build,
      act: (b) => b.add(const SendScheduledNow('s1')),
      verify: (_) {
        verifyNever(() => repo.reschedule(any(), any()));
        verifyNever(() => sms.sendSms(any(), any()));
      },
    );
  });

  group('jitter and delivery', () {
    blocTest<ScheduledMessageBloc, ScheduledState>(
      'a due row still inside its jitter window is left alone',
      setUp: () {
        final row = _jitteredNotYetDue();
        when(() => repo.getDue(any())).thenAnswer((_) async => [row]);
      },
      build: build,
      act: (b) => b.add(const DeliverDueScheduled()),
      wait: const Duration(milliseconds: 10),
      verify: (_) {
        verifyNever(() => sms.sendSms(any(), any()));
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'ارسال فوری sends through an unelapsed jitter window',
      setUp: () {
        final row = _jitteredNotYetDue();
        when(() => repo.getById('s1')).thenAnswer((_) async => row);
        claimYieldsOnce([row]);
        when(
          () => sms.sendSms(any(), any()),
        ).thenAnswer((_) async => const SmsServiceResult.ok());
      },
      build: build,
      act: (b) => b.add(const SendScheduledNow('s1')),
      verify: (_) {
        verify(() => sms.sendSms('09120000000', 'سلام')).called(1);
      },
    );
  });

  group('SaveScheduled / CancelScheduled', () {
    blocTest<ScheduledMessageBloc, ScheduledState>(
      'persists a new schedule and reloads',
      build: build,
      act: (b) => b.add(
        SaveScheduled(
          phoneNumber: '09121112233',
          body: 'یادآوری',
          scheduledAt: DateTime(2026, 6, 1, 9),
        ),
      ),
      expect: () => [isA<ScheduledLoaded>()],
      verify: (_) {
        final captured =
            verify(() => repo.upsert(captureAny())).captured.last
                as ScheduledMessage;
        expect(captured.phoneNumber, '09121112233');
        expect(captured.body, 'یادآوری');
        expect(captured.status, ScheduleStatus.pending);
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'ignores an empty body',
      build: build,
      act: (b) => b.add(
        SaveScheduled(
          phoneNumber: '09121112233',
          body: '   ',
          scheduledAt: DateTime(2026, 6, 1, 9),
        ),
      ),
      expect: () => const <ScheduledState>[],
      verify: (_) => verifyNever(() => repo.upsert(any())),
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'cancel marks the schedule cancelled',
      build: build,
      act: (b) => b.add(const CancelScheduled('s1')),
      expect: () => [isA<ScheduledLoaded>()],
      verify: (_) => verify(() => repo.cancel('s1')).called(1),
    );
  });
}
