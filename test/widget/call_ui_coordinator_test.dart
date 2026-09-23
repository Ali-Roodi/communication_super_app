import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/core/navigation/call_ui_coordinator.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/models/phone_match.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/screens/in_call_screen.dart';
import 'package:communication_super_app/features/dialer/screens/incoming_call_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';

class _MockContactRepository extends Mock implements ContactRepository {}

class _MockNativeCallService extends Mock implements NativeCallService {}

/// [CallUiCoordinator] owns the call screens, and the only way it can be wrong
/// is by leaving one behind. That is what these tests are for.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockContactRepository repo;
  late _MockNativeCallService callService;
  late StreamController<CallInfo> events;

  setUp(() {
    repo = _MockContactRepository();
    callService = _MockNativeCallService();
    events = StreamController<CallInfo>.broadcast();

    when(() => repo.getAllContacts()).thenAnswer((_) async => <ContactModel>[]);
    when(() => repo.matchPhoneDigits(any(), any())).thenReturn(<PhoneMatch>[]);
    when(() => callService.callEvents).thenAnswer((_) => events.stream);
    // The coordinator reports the call screen's visibility to the shade card on
    // every push and teardown; nothing here depends on the answer.
    when(
      () => callService.setCallScreenVisible(visible: any(named: 'visible')),
    ).thenAnswer((_) async {});
  });

  tearDown(() => events.close());

  Future<DialerBloc> pumpApp(WidgetTester tester) async {
    final bloc = DialerBloc(repo, callService: callService);
    await tester.pumpWidget(
      BlocProvider<DialerBloc>.value(
        value: bloc,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          home: const CallUiCoordinator(
            child: Scaffold(body: Text('inbox', key: Key('app-root'))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return bloc;
  }

  /// Pushes one telecom event and lets the coordinator navigate on it.
  Future<void> emit(WidgetTester tester, CallInfo info) async {
    events.add(info);
    await tester.pump();
    await tester.pump();
  }

  /// The coordinator lingers on an ended call for 600 ms before removing its
  /// route — see the `idle` branch.
  Future<void> settleTeardown(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a call-waiting ring over a live call leaves nothing behind when both end',
    (tester) async {
      final bloc = await pumpApp(tester);
      addTearDown(bloc.close);

      // Call A is up.
      await emit(
        tester,
        const CallInfo(
          event: NativeCallEvent.active,
          phone: '09121111111',
          direction: 'incoming',
        ),
      );
      expect(find.byType(InCallScreen), findsOneWidget);

      // Call B rings while A is still connected (call waiting). The incoming
      // screen goes over the in-call screen — and the in-call screen must be
      // taken down with it, not merely forgotten.
      await emit(
        tester,
        const CallInfo(
          event: NativeCallEvent.incoming,
          phone: '09122222222',
          direction: 'incoming',
        ),
      );
      expect(find.byType(IncomingCallScreen), findsOneWidget);
      expect(find.byType(InCallScreen), findsNothing);

      // B's caller gives up; telecom hands the UI back to the survivor.
      await emit(
        tester,
        const CallInfo(
          event: NativeCallEvent.active,
          phone: '09121111111',
          direction: 'incoming',
        ),
      );
      expect(find.byType(InCallScreen), findsOneWidget);
      expect(find.byType(IncomingCallScreen), findsNothing);

      // A ends. THIS is the regression: the coordinator used to remember only
      // the route it had pushed last, so the orphaned screens surfaced here —
      // the user was left staring at a dead incoming-call screen for somebody
      // who had rung off minutes earlier, with no call anywhere on the phone.
      await emit(
        tester,
        const CallInfo(
          event: NativeCallEvent.disconnected,
          phone: '09121111111',
          direction: 'incoming',
        ),
      );
      await settleTeardown(tester);

      expect(find.byType(IncomingCallScreen), findsNothing);
      expect(find.byType(InCallScreen), findsNothing);
      expect(find.byKey(const Key('app-root')), findsOneWidget);
    },
  );

  testWidgets('answering an incoming call swaps the screen and leaves one', (
    tester,
  ) async {
    final bloc = await pumpApp(tester);
    addTearDown(bloc.close);

    await emit(
      tester,
      const CallInfo(
        event: NativeCallEvent.incoming,
        phone: '09121111111',
        direction: 'incoming',
      ),
    );
    expect(find.byType(IncomingCallScreen), findsOneWidget);

    await emit(
      tester,
      const CallInfo(
        event: NativeCallEvent.active,
        phone: '09121111111',
        direction: 'incoming',
      ),
    );
    expect(find.byType(InCallScreen), findsOneWidget);
    expect(find.byType(IncomingCallScreen), findsNothing);

    await emit(
      tester,
      const CallInfo(
        event: NativeCallEvent.disconnected,
        phone: '09121111111',
        direction: 'incoming',
      ),
    );
    await settleTeardown(tester);

    expect(find.byType(InCallScreen), findsNothing);
    expect(find.byKey(const Key('app-root')), findsOneWidget);
  });

  // ── Heads-up card vs full screen ──────────────────────────────────────────
  //
  // A call that rings while the phone is in use is announced by the system's
  // heads-up card alone (Google Phone); the native side says so with
  // `showScreen: false`, and the full screen opens only when that flips.

  const ringOnCard = CallInfo(
    event: NativeCallEvent.incoming,
    phone: '09122222222',
    direction: 'incoming',
    showScreen: false,
  );

  testWidgets('a ring on the heads-up card opens no screen until tapped', (
    tester,
  ) async {
    final bloc = await pumpApp(tester);
    addTearDown(bloc.close);

    await emit(tester, ringOnCard);
    expect(find.byType(IncomingCallScreen), findsNothing);
    expect(find.byKey(const Key('app-root')), findsOneWidget);
    expect(CallUiCoordinator.minimized.value, isFalse);

    // The card was tapped: the same ring, now wanting the screen.
    await emit(
      tester,
      const CallInfo(
        event: NativeCallEvent.incoming,
        phone: '09122222222',
        direction: 'incoming',
      ),
    );
    expect(find.byType(IncomingCallScreen), findsOneWidget);

    // Asked again (SHOW_CALL_UI after the state already flipped) — still one.
    CallUiCoordinator.restore();
    await tester.pump();
    expect(find.byType(IncomingCallScreen), findsOneWidget);
  });

  testWidgets('answering from the card opens the in-call screen', (
    tester,
  ) async {
    final bloc = await pumpApp(tester);
    addTearDown(bloc.close);

    await emit(tester, ringOnCard);
    await emit(
      tester,
      const CallInfo(
        event: NativeCallEvent.active,
        phone: '09122222222',
        direction: 'incoming',
      ),
    );
    expect(find.byType(InCallScreen), findsOneWidget);
  });

  testWidgets('declining from the card opens nothing and leaves nothing', (
    tester,
  ) async {
    final bloc = await pumpApp(tester);
    addTearDown(bloc.close);

    await emit(tester, ringOnCard);
    await emit(
      tester,
      const CallInfo(
        event: NativeCallEvent.disconnected,
        phone: '09122222222',
        direction: 'incoming',
      ),
    );
    await settleTeardown(tester);
    expect(find.byType(IncomingCallScreen), findsNothing);
    expect(find.byType(InCallScreen), findsNothing);
    expect(find.byKey(const Key('app-root')), findsOneWidget);
  });

  testWidgets(
    'a second call declined from the card leaves the first one put away',
    (tester) async {
      final bloc = await pumpApp(tester);
      addTearDown(bloc.close);

      // Call A is up, and the user put its screen away.
      await emit(
        tester,
        const CallInfo(
          event: NativeCallEvent.active,
          phone: '09121111111',
          direction: 'incoming',
        ),
      );
      CallUiCoordinator.minimize();
      await tester.pump();
      expect(find.byType(InCallScreen), findsNothing);
      expect(CallUiCoordinator.minimized.value, isTrue);

      // B rings on the card and is declined; telecom hands back to A.
      await emit(tester, ringOnCard);
      await emit(
        tester,
        const CallInfo(
          event: NativeCallEvent.active,
          phone: '09121111111',
          direction: 'incoming',
        ),
      );
      expect(find.byType(InCallScreen), findsNothing,
          reason: 'A was put away; B never had a screen to swap back from');
      expect(CallUiCoordinator.minimized.value, isTrue);

      await emit(
        tester,
        const CallInfo(
          event: NativeCallEvent.disconnected,
          phone: '09121111111',
          direction: 'incoming',
        ),
      );
      await settleTeardown(tester);
    },
  );

  testWidgets('back on the incoming screen puts it away without a bar', (
    tester,
  ) async {
    final bloc = await pumpApp(tester);
    addTearDown(bloc.close);

    await emit(
      tester,
      const CallInfo(
        event: NativeCallEvent.incoming,
        phone: '09121111111',
        direction: 'incoming',
      ),
    );
    expect(find.byType(IncomingCallScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(IncomingCallScreen), findsNothing);
    expect(find.byKey(const Key('app-root')), findsOneWidget);
    // Not "a call in the background" — the heads-up card takes it over.
    expect(CallUiCoordinator.minimized.value, isFalse);

    // The card is tapped: the screen comes back.
    CallUiCoordinator.restore();
    await tester.pump();
    expect(find.byType(IncomingCallScreen), findsOneWidget);
  });
}
