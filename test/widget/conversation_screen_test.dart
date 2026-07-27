import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/scheduled_event.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';
import 'package:communication_super_app/features/messages/repositories/scheduled_message_repository.dart';
import 'package:communication_super_app/features/messages/services/native_scheduled_sms_service.dart';
import 'package:communication_super_app/features/messages/services/sms_service.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_bubble.dart';
import 'package:communication_super_app/features/messages/screens/widgets/scheduled_bubble.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';

class _MockMessageRepository extends Mock implements MessageRepository {}

class _MockSmsService extends Mock implements SmsService {}

class _MockContactRepository extends Mock implements ContactRepository {}

class _MockBlockedNumbersRepository extends Mock
    implements BlockedNumbersRepository {}

class _MockScheduledRepository extends Mock
    implements ScheduledMessageRepository {}

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

MessageModel _msg(
  String id, {
  required DateTime at,
  MessageType type = MessageType.received,
  String body = 'سلام',
}) => MessageModel(
  id: id,
  threadId: '09120000000',
  phoneNumber: '09120000000',
  body: body,
  type: type,
  status: MessageStatus.delivered,
  timestamp: at,
);

ScheduledMessage _scheduled({String body = 'پیام زمان‌بندی‌شده'}) =>
    ScheduledMessage(
      id: 's1',
      phoneNumber: '09120000000',
      body: body,
      scheduledAt: DateTime.now().add(const Duration(hours: 3)),
      createdAt: DateTime.now(),
    );

void main() {
  late _MockMessageRepository repo;
  late _MockSmsService sms;
  late _MockContactRepository contacts;
  late _MockBlockedNumbersRepository blockedRepo;
  late _MockScheduledRepository scheduledRepo;

  setUp(() {
    repo = _MockMessageRepository();
    sms = _MockSmsService();
    contacts = _MockContactRepository();
    blockedRepo = _MockBlockedNumbersRepository();
    scheduledRepo = _MockScheduledRepository();

    when(() => repo.markThreadAsRead(any())).thenAnswer((_) async {});
    // LoadThreads (fired on dispose) needs these stubbed so it can't throw.
    when(
      () => sms.syncDeviceMessages(forceRefresh: any(named: 'forceRefresh')),
    ).thenAnswer((_) async {});
    when(() => sms.isListening).thenReturn(true);
    when(
      () => repo.getAllThreads(
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        archived: any(named: 'archived'),
      ),
    ).thenAnswer((_) async => const []);
    when(() => contacts.getAllContacts()).thenAnswer((_) async => const []);
    when(() => blockedRepo.getBlocked()).thenAnswer((_) async => const []);
    when(
      () => scheduledRepo.getAll(status: any(named: 'status')),
    ).thenAnswer((_) async => const <ScheduledMessage>[]);
  });

  Widget harness() {
    final messageBloc = MessageBloc(
      repository: repo,
      smsService: sms,
      contactRepository: contacts,
    );
    final scheduledBloc = ScheduledMessageBloc(
      repository: scheduledRepo,
      nativeScheduler: _NoopNative(),
      autoDeliver: false,
    )..add(const LoadScheduled());
    return MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: messageBloc),
          BlocProvider.value(value: scheduledBloc),
          BlocProvider(create: (_) => BlockedNumbersBloc(blockedRepo)),
          // The composer/bubbles read «پیش‌نمایش خودکار پیوند» from here.
          BlocProvider(create: (_) => SettingsBloc()),
        ],
        child: const ConversationScreen(
          threadId: '09120000000',
          phoneNumber: '09120000000',
          contactName: 'علی',
        ),
      ),
    );
  }

  testWidgets('renders one bubble per loaded message', (tester) async {
    // Repository returns DESC (newest first); the bloc reverses to chronological.
    when(
      () => repo.getMessagesByThread(
        any(),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        orderDesc: any(named: 'orderDesc'),
      ),
    ).thenAnswer(
      (_) async => [
        _msg('m2', at: DateTime(2026, 1, 1, 12, 1), body: 'دوم'),
        _msg('m1', at: DateTime(2026, 1, 1, 12, 0), body: 'اول'),
      ],
    );

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(MessageBubble), findsNWidgets(2));
    expect(find.text('اول'), findsOneWidget);
    expect(find.text('دوم'), findsOneWidget);
  });

  testWidgets('shows the empty placeholder when there are no messages', (
    tester,
  ) async {
    when(
      () => repo.getMessagesByThread(
        any(),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        orderDesc: any(named: 'orderDesc'),
      ),
    ).thenAnswer((_) async => const []);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(MessageBubble), findsNothing);
    expect(find.text('هنوز پیامی نیست'), findsOneWidget);
  });

  testWidgets('separates messages from different days with date chips', (
    tester,
  ) async {
    // Use now-relative timestamps so the day-separator labels are the
    // deterministic «امروز»/«دیروز» strings regardless of the locale date format.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9);
    final yesterday = today.subtract(const Duration(days: 1));
    when(
      () => repo.getMessagesByThread(
        any(),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        orderDesc: any(named: 'orderDesc'),
      ),
    ).thenAnswer(
      (_) async => [
        _msg('m2', at: today, body: 'پیام امروز'),
        _msg('m1', at: yesterday, body: 'پیام دیروز'),
      ],
    );

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(MessageBubble), findsNWidgets(2));
    // The separator reads «امروز • ۰۹:۰۰» (label + time), like Google Messages.
    // Anchored so a message body that happens to contain the word doesn't match.
    expect(find.textContaining(RegExp('^امروز • ')), findsOneWidget);
    expect(find.textContaining(RegExp('^دیروز • ')), findsOneWidget);
  });

  testWidgets('a pending schedule for this thread renders as a ghost bubble', (
    tester,
  ) async {
    when(
      () => repo.getMessagesByThread(
        any(),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        orderDesc: any(named: 'orderDesc'),
      ),
    ).thenAnswer((_) async => [_msg('m1', at: DateTime.now())]);
    when(
      () => scheduledRepo.getAll(status: any(named: 'status')),
    ).thenAnswer((_) async => [_scheduled()]);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(MessageBubble), findsOneWidget);
    expect(find.byType(ScheduledBubble), findsOneWidget);
    expect(find.text('پیام زمان‌بندی‌شده'), findsOneWidget);
  });

  testWidgets('a schedule for another thread is not shown', (tester) async {
    when(
      () => repo.getMessagesByThread(
        any(),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        orderDesc: any(named: 'orderDesc'),
      ),
    ).thenAnswer((_) async => const []);
    when(() => scheduledRepo.getAll(status: any(named: 'status'))).thenAnswer(
      (_) async => [
        ScheduledMessage(
          id: 's2',
          phoneNumber: '09129999999',
          body: 'مال یک چت دیگر',
          scheduledAt: DateTime.now().add(const Duration(hours: 1)),
          createdAt: DateTime.now(),
        ),
      ],
    );

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(ScheduledBubble), findsNothing);
    expect(find.text('هنوز پیامی نیست'), findsOneWidget);
  });

  testWidgets('long-pressing a scheduled bubble opens the actions sheet', (
    tester,
  ) async {
    when(
      () => repo.getMessagesByThread(
        any(),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        orderDesc: any(named: 'orderDesc'),
      ),
    ).thenAnswer((_) async => const []);
    when(
      () => scheduledRepo.getAll(status: any(named: 'status')),
    ).thenAnswer((_) async => [_scheduled()]);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(ScheduledBubble));
    await tester.pumpAndSettle();

    expect(find.text('ارسال فوری'), findsOneWidget);
    expect(find.text('ویرایش پیام'), findsOneWidget);
    expect(find.text('لغو زمان‌بندی'), findsOneWidget);
  });
}
