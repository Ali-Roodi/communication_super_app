import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/scheduled_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_event.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_state.dart';
import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';
import 'package:communication_super_app/features/messages/repositories/scheduled_message_repository.dart';
import 'package:communication_super_app/features/messages/services/sms_service.dart';

class _MockRepo extends Mock implements ScheduledMessageRepository {}

class _MockSms extends Mock implements SmsService {}

ScheduledMessage _due({
  String id = 's1',
  ScheduleRepeat repeat = ScheduleRepeat.none,
}) => ScheduledMessage(
  id: id,
  phoneNumber: '09120000000',
  body: 'سلام',
  scheduledAt: DateTime(2026, 1, 1, 9),
  repeat: repeat,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  setUpAll(() {
    registerFallbackValue(_due());
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
  });

  ScheduledMessageBloc build() => ScheduledMessageBloc(
    repository: repo,
    smsService: sms,
    autoDeliver: false,
  );

  group('DeliverDueScheduled', () {
    blocTest<ScheduledMessageBloc, ScheduledState>(
      'sends each due message and completes a one-shot',
      setUp: () {
        when(() => repo.getDue(any())).thenAnswer((_) async => [_due()]);
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
      'marks a message failed when sending fails',
      setUp: () {
        when(() => repo.getDue(any())).thenAnswer((_) async => [_due()]);
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
        expect(captured.status, ScheduleStatus.failed);
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'a recurring message stays pending with an advanced fire time',
      setUp: () {
        when(
          () => repo.getDue(any()),
        ).thenAnswer((_) async => [_due(repeat: ScheduleRepeat.daily)]);
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
        expect(captured.scheduledAt, DateTime(2026, 1, 2, 9));
      },
    );

    blocTest<ScheduledMessageBloc, ScheduledState>(
      'does nothing when no message is due',
      setUp: () {
        when(() => repo.getDue(any())).thenAnswer((_) async => const []);
      },
      build: build,
      act: (b) => b.add(const DeliverDueScheduled()),
      expect: () => const <ScheduledState>[],
      verify: (_) => verifyNever(() => sms.sendSms(any(), any())),
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
