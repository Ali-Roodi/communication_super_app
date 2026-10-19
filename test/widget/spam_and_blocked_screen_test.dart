import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/message_event.dart';
import 'package:communication_super_app/features/messages/bloc/message_state.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';
import 'package:communication_super_app/features/messages/screens/spam_and_blocked_screen.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';

class _MockBlocked extends MockBloc<BlockedNumbersEvent, BlockedNumbersState>
    implements BlockedNumbersBloc {}

class _MockMessages extends MockBloc<MessageEvent, MessageState>
    implements MessageBloc {}

class _MockSettings extends MockBloc<SettingsEvent, SettingsState>
    implements SettingsBloc {}

class _MockMessageRepository extends Mock implements MessageRepository {}

BlockedNumberModel _blocked(String number, {bool spam = false}) =>
    BlockedNumberModel(
      id: number,
      phoneNumber: number,
      normalized: number,
      createdAt: DateTime(2026, 1, 1),
      isSpam: spam,
    );

void main() {
  setUpAll(() {
    registerFallbackValue(const LoadBlocked());
    registerFallbackValue(const LoadThreads());
  });

  late _MockBlocked blocked;
  late _MockMessages messages;
  late _MockSettings settings;
  late _MockMessageRepository repo;

  // One reported sender with a conversation, one plain block without.
  final numbers = [
    _blocked('09121112233', spam: true),
    _blocked('09120000000'),
  ];

  setUp(() {
    blocked = _MockBlocked();
    messages = _MockMessages();
    settings = _MockSettings();
    repo = _MockMessageRepository();
    whenListen(
      blocked,
      const Stream<BlockedNumbersState>.empty(),
      initialState: BlockedNumbersLoaded(numbers),
    );
    whenListen(
      messages,
      const Stream<MessageState>.empty(),
      initialState: const ThreadsLoaded([]),
    );
    whenListen(
      settings,
      const Stream<SettingsState>.empty(),
      initialState: const SettingsState(),
    );
    when(
      () => repo.getAllThreads(
        restrictToThreadIds: any(named: 'restrictToThreadIds'),
        includeBlocked: any(named: 'includeBlocked'),
        archived: any(named: 'archived'),
      ),
    ).thenAnswer((call) async {
      if (call.namedArguments[#archived] == true) return const [];
      return [
        MessageThread(
          threadId: '09121112233',
          phoneNumber: '09121112233',
          lastMessage: 'برنده شدید',
          lastMessageTime: DateTime(2026, 1, 1),
        ),
      ];
    });
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<BlockedNumbersBloc>.value(value: blocked),
          BlocProvider<MessageBloc>.value(value: messages),
          BlocProvider<SettingsBloc>.value(value: settings),
        ],
        child: MaterialApp(home: SpamAndBlockedScreen(messages: repo)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Lets the undo snack's own timer run out, so no timer outlives the test.
  Future<void> drainSnack(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('both lists render, with the conversation preview', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('هرزنامه'), findsWidgets);
    expect(find.text('مسدودشده'), findsOneWidget);
    expect(find.text('برنده شدید'), findsOneWidget);
    expect(find.text('بدون گفتگو'), findsOneWidget);
    // The call rules stay reachable.
    expect(find.text('مسدود کردن تماس'), findsOneWidget);
  });

  testWidgets('long-press selects; «انتخاب همه» then «رفع مسدودی» unblocks '
      'every number in one event, and «واگرد» re-blocks with the report', (
    tester,
  ) async {
    await pump(tester);
    await tester.longPress(find.text('بدون گفتگو'));
    await tester.pumpAndSettle();
    // The call rules row stays where it was — the list must not jump.
    expect(find.text('مسدود کردن تماس'), findsOneWidget);

    await tester.tap(find.byTooltip('انتخاب همه'));
    await tester.pump();
    await tester.tap(find.byTooltip('رفع مسدودی'));
    await tester.pump();

    verify(
      () => blocked.add(const UnblockNumbers(['09121112233', '09120000000'])),
    ).called(1);
    // Selection is over.
    expect(find.byTooltip('رفع مسدودی'), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('واگرد'));
    await tester.pump();
    verify(
      () => blocked.add(const BlockNumber('09121112233', report: true)),
    ).called(1);
    verify(() => blocked.add(const BlockNumber('09120000000'))).called(1);
    await drainSnack(tester);
  });

  testWidgets('«حذف گفتگو» asks first and deletes only real conversations', (
    tester,
  ) async {
    await pump(tester);
    await tester.longPress(find.text('برنده شدید'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('انتخاب همه'));
    await tester.pump();

    await tester.tap(find.byTooltip('حذف گفتگو'));
    await tester.pumpAndSettle();
    // One of the two has a conversation; the dialog counts that one.
    expect(find.text('گفتگو حذف شود؟'), findsOneWidget);

    await tester.tap(find.text('انصراف'));
    await tester.pumpAndSettle();
    verifyNever(() => messages.add(any(that: isA<DeleteThreads>())));

    await tester.tap(find.byTooltip('حذف گفتگو'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف'));
    await tester.pumpAndSettle();
    verify(() => messages.add(const DeleteThreads(['09121112233']))).called(1);
    // The numbers themselves stay blocked.
    verifyNever(() => blocked.add(any(that: isA<UnblockNumbers>())));
    await drainSnack(tester);
  });

  testWidgets('back leaves the selection before the page', (tester) async {
    await pump(tester);
    await tester.longPress(find.text('بدون گفتگو'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('رفع مسدودی'), findsOneWidget);

    final popped = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    expect(find.byTooltip('رفع مسدودی'), findsNothing);
    expect(find.byType(SpamAndBlockedScreen), findsOneWidget);
  });
}
