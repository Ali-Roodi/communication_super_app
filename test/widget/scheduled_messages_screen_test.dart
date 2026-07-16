import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/scheduled_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_event.dart';
import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';
import 'package:communication_super_app/features/messages/repositories/scheduled_message_repository.dart';
import 'package:communication_super_app/features/messages/services/native_scheduled_sms_service.dart';
import 'package:communication_super_app/features/messages/screens/scheduled_messages_screen.dart';

class _MockRepo extends Mock implements ScheduledMessageRepository {}

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

ScheduledMessage _msg() => ScheduledMessage(
  id: 's1',
  phoneNumber: '09120000000',
  contactName: 'علی',
  body: 'یادآوری جلسه',
  scheduledAt: DateTime.now().add(const Duration(hours: 2)),
  repeat: ScheduleRepeat.daily,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  late _MockRepo repo;

  setUp(() {
    repo = _MockRepo();
  });

  Widget harness() {
    final bloc = ScheduledMessageBloc(
      repository: repo,
      nativeScheduler: _NoopNative(),
      autoDeliver: false,
    )..add(const LoadScheduled());
    return MaterialApp(
      home: BlocProvider.value(
        value: bloc,
        child: const ScheduledMessagesScreen(),
      ),
    );
  }

  testWidgets('shows the empty placeholder when there are no schedules', (
    tester,
  ) async {
    when(
      () => repo.getAll(status: any(named: 'status')),
    ).thenAnswer((_) async => const []);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('پیام زمان‌بندی‌شده‌ای نیست'), findsOneWidget);
  });

  testWidgets('renders a pending schedule with recipient and body', (
    tester,
  ) async {
    when(
      () => repo.getAll(status: any(named: 'status')),
    ).thenAnswer((_) async => [_msg()]);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('در انتظار ارسال'), findsOneWidget);
    expect(find.text('علی'), findsOneWidget);
    expect(find.text('یادآوری جلسه'), findsOneWidget);
  });
}
