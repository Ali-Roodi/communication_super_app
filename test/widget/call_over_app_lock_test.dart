import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/core/navigation/call_ui_coordinator.dart';
import 'package:communication_super_app/core/widgets/app_lock_wrapper.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/models/phone_match.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/screens/in_call_screen.dart';
import 'package:communication_super_app/features/dialer/screens/incoming_call_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';

class _MockContactRepository extends Mock implements ContactRepository {}

class _MockNativeCallService extends Mock implements NativeCallService {}

/// A ringing phone and the app lock land on the same navigator at the same
/// moment — the ring is what brings the app back — and which one ends up on
/// top decided whether the call could be answered without the PIN. It could
/// not: «برای پاسخ به تماس ورودی حتما باید رمز اپ رو وارد کرد». These pin the
/// order down, both ways round, with «رمز برای پاسخ به تماس» off and on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_secure_storage, in memory — AuthRepository reads the auth type
  // and the PIN length from it.
  final store = <String, String>{};
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  late _MockContactRepository contacts;
  late _MockNativeCallService callService;
  late StreamController<CallInfo> events;

  void usePrefs({required bool pinToAnswer}) {
    SharedPreferences.setMockInitialValues({
      // «فوراً»: every trip to the background locks.
      'set_relockAfterSeconds': 0,
      'set_pinToAnswerCalls': pinToAnswer,
    });
  }

  setUp(() {
    store
      ..clear()
      ..['auth_type'] = 'pin';
    AuthRepository.resetSessionForTest();
    usePrefs(pinToAnswer: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = (call.arguments as Map?) ?? const {};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'write':
              store[key!] = args['value'] as String;
              return null;
            case 'read':
              return store[key];
            case 'delete':
              store.remove(key);
              return null;
            case 'containsKey':
              return store.containsKey(key);
            case 'readAll':
              return Map<String, String>.from(store);
          }
          return null;
        });

    contacts = _MockContactRepository();
    callService = _MockNativeCallService();
    events = StreamController<CallInfo>.broadcast();
    when(
      () => contacts.getAllContacts(),
    ).thenAnswer((_) async => <ContactModel>[]);
    when(
      () => contacts.matchPhoneDigits(any(), any()),
    ).thenReturn(<PhoneMatch>[]);
    when(() => callService.callEvents).thenAnswer((_) => events.stream);
    when(
      () => callService.setCallScreenVisible(visible: any(named: 'visible')),
    ).thenAnswer((_) async {});
    // Coming back to the app re-asks telecom; the call is still there.
    when(() => callService.isInCall()).thenAnswer((_) async => true);
    when(() => callService.getAudioState()).thenAnswer((_) async => null);
  });

  tearDown(() {
    events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  /// Lets the async reads (secure storage, preferences) and the navigation
  /// they lead to run. Not `pumpAndSettle`: the incoming screen animates.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// [unlocked]: a session the user has already opened with the PIN; false is
  /// a process the ring cold-started onto its launch PIN screen.
  Future<void> pumpApp(WidgetTester tester, {required bool unlocked}) async {
    await AuthRepository().setAuthenticated(unlocked);
    final dialer = DialerBloc(contacts, callService: callService);
    final auth = AuthBloc(AuthRepository())..add(const CheckAuthStatus());
    addTearDown(dialer.close);
    addTearDown(auth.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<DialerBloc>.value(value: dialer),
          BlocProvider<AuthBloc>.value(value: auth),
        ],
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          builder: (context, child) => AppLockWrapper(child: child!),
          home: const CallUiCoordinator(
            child: Scaffold(body: Text('inbox', key: Key('app-root'))),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> emit(WidgetTester tester, NativeCallEvent event) async {
    events.add(
      CallInfo(event: event, phone: '09121111111', direction: 'incoming'),
    );
    await settle(tester);
  }

  /// The app went to the background and came back — for a ringing phone, the
  /// full-screen intent bringing it forward.
  Future<void> leaveAndReturn(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
  }

  /// What the user is looking at: only the top route is onstage.
  Finder onTop(Type type) => find.byType(type);

  Future<void> endCall(WidgetTester tester) async {
    await emit(tester, NativeCallEvent.disconnected);
    await tester.pump(const Duration(milliseconds: 700));
    await settle(tester);
  }

  group('«رمز برای پاسخ به تماس» off (the default)', () {
    testWidgets(
      'a lock that lands on a ringing call goes under it, and outlives it',
      (tester) async {
        await pumpApp(tester, unlocked: true);
        await emit(tester, NativeCallEvent.incoming);
        expect(onTop(IncomingCallScreen), findsOneWidget);

        // THE regression: the relock pushed over the incoming screen, and the
        // phone could not be answered without the PIN.
        await leaveAndReturn(tester);
        expect(onTop(IncomingCallScreen), findsOneWidget);
        expect(onTop(RelockScreen), findsNothing);

        // Declined: the app is locked, not left open behind the call.
        await endCall(tester);
        expect(onTop(RelockScreen), findsOneWidget);
        expect(onTop(IncomingCallScreen), findsNothing);
      },
    );

    testWidgets('a ring that arrives over the lock is answerable', (
      tester,
    ) async {
      await pumpApp(tester, unlocked: true);
      await leaveAndReturn(tester);
      expect(onTop(RelockScreen), findsOneWidget);

      await emit(tester, NativeCallEvent.incoming);
      expect(onTop(IncomingCallScreen), findsOneWidget);
    });

    testWidgets('a ring that cold-starts the app goes over its PIN screen', (
      tester,
    ) async {
      await pumpApp(tester, unlocked: false);
      await emit(tester, NativeCallEvent.incoming);
      expect(onTop(IncomingCallScreen), findsOneWidget);
      expect(onTop(RelockScreen), findsNothing);
    });
  });

  group('«رمز برای پاسخ به تماس» on', () {
    setUp(() => usePrefs(pinToAnswer: true));

    testWidgets('a ringing call waits behind the lock', (tester) async {
      await pumpApp(tester, unlocked: true);
      await emit(tester, NativeCallEvent.incoming);
      // Unlocked session: nothing to ask.
      expect(onTop(IncomingCallScreen), findsOneWidget);

      await leaveAndReturn(tester);
      expect(onTop(RelockScreen), findsOneWidget);
      expect(onTop(IncomingCallScreen), findsNothing);

      // Tapping the incoming card again must not be a way past the PIN.
      CallUiCoordinator.restore();
      await settle(tester);
      expect(onTop(RelockScreen), findsOneWidget);
    });

    testWidgets('a ring that cold-starts the app is covered by the lock', (
      tester,
    ) async {
      await pumpApp(tester, unlocked: false);
      await emit(tester, NativeCallEvent.incoming);
      expect(onTop(RelockScreen), findsOneWidget);
      expect(onTop(IncomingCallScreen), findsNothing);
    });

    testWidgets('a call answered elsewhere (headset, car) is never behind it', (
      tester,
    ) async {
      await pumpApp(tester, unlocked: false);
      await emit(tester, NativeCallEvent.incoming);
      expect(onTop(RelockScreen), findsOneWidget);

      await emit(tester, NativeCallEvent.active);
      expect(onTop(InCallScreen), findsOneWidget);
      expect(onTop(RelockScreen), findsNothing);
    });
  });
}
