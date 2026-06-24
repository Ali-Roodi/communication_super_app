import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';
import 'package:communication_super_app/features/messages/services/sms_service.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_bubble.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';

class _MockMessageRepository extends Mock implements MessageRepository {}

class _MockSmsService extends Mock implements SmsService {}

class _MockContactRepository extends Mock implements ContactRepository {}

class _MockBlockedNumbersRepository extends Mock
    implements BlockedNumbersRepository {}

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

void main() {
  late _MockMessageRepository repo;
  late _MockSmsService sms;
  late _MockContactRepository contacts;
  late _MockBlockedNumbersRepository blockedRepo;

  setUp(() {
    repo = _MockMessageRepository();
    sms = _MockSmsService();
    contacts = _MockContactRepository();
    blockedRepo = _MockBlockedNumbersRepository();

    when(() => repo.markThreadAsRead(any())).thenAnswer((_) async {});
    // LoadThreads (fired on dispose) needs these stubbed so it can't throw.
    when(
      () => sms.importDeviceMessages(forceRefresh: any(named: 'forceRefresh')),
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
  });

  Widget harness() {
    final messageBloc = MessageBloc(
      repository: repo,
      smsService: sms,
      contactRepository: contacts,
    );
    return MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: messageBloc),
          BlocProvider(create: (_) => BlockedNumbersBloc(blockedRepo)),
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
    expect(find.text('امروز'), findsOneWidget);
    expect(find.text('دیروز'), findsOneWidget);
  });
}
