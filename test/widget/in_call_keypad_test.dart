import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/models/phone_match.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/screens/in_call_screen.dart';
import 'package:communication_super_app/features/dialer/services/auto_redial_policy.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';

class _MockContactRepository extends Mock implements ContactRepository {}

class _MockNativeCallService extends Mock implements NativeCallService {}

/// The in-call keypad («صفحه‌کلید» during a call).
///
/// It is part of the call screen rather than a bottom sheet — see
/// `docs/architecture/dialer-and-calls.md` — which means its layout is this
/// screen's problem, and a `Column` of naturally-sized children silently piles
/// everything against the top of a tall screen instead of failing. So these
/// tests assert **geometry**, not just presence.
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
    when(() => repo.getContactByPhoneNumber(any())).thenAnswer((_) async => null);
    when(() => callService.callEvents).thenAnswer((_) => events.stream);
    when(() => callService.startDtmf(any())).thenAnswer((_) async {});
    when(() => callService.stopDtmf()).thenAnswer((_) async {});
    when(
      () => callService.setCallScreenVisible(visible: any(named: 'visible')),
    ).thenAnswer((_) async {});
  });

  tearDown(() => events.close());

  Future<DialerBloc> pumpCall(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bloc = DialerBloc(repo, callService: callService);
    await tester.pumpWidget(
      BlocProvider<DialerBloc>.value(
        value: bloc,
        child: const MaterialApp(
          home: InCallScreen(phone: '09121234567', contactName: 'علی رودی'),
        ),
      ),
    );
    events.add(
      const CallInfo(
        event: NativeCallEvent.active,
        phone: '09121234567',
        direction: 'outgoing',
      ),
    );
    await tester.pump();
    await tester.pump();
    return bloc;
  }

  Future<void> openKeypad(WidgetTester tester) async {
    await tester.tap(find.text('صفحه‌کلید'));
    await tester.pumpAndSettle();
  }

  for (final size in const <Size>[
    Size(1080, 2400), // the test device
    Size(720, 1280), // a small, short screen — the tightest case
    Size(1440, 3200), // a tall flagship
  ]) {
    testWidgets('keypad lays out inside ${size.width.toInt()}x'
        '${size.height.toInt()} without overflow', (tester) async {
      final bloc = await pumpCall(tester, size);
      addTearDown(bloc.close);
      await openKeypad(tester);

      // Every key is present and on screen.
      final screen = tester.getRect(find.byType(InCallScreen).first);
      for (final digit in const ['۱', '۵', '۹', '۰', '*', '#']) {
        final key = find.text(digit);
        expect(key, findsOneWidget, reason: 'key $digit is missing');
        final rect = tester.getRect(key);
        expect(
          screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
          isTrue,
          reason: 'key $digit at $rect falls outside the screen $screen',
        );
      }

      // «پایان» and «بستن» are both reachable, below the keys.
      final lastRow = tester.getRect(find.text('۰'));
      expect(tester.getRect(find.text('پایان')).top, greaterThan(lastRow.bottom));
      expect(tester.getRect(find.text('بستن')).top, greaterThan(lastRow.bottom));

      // The grid is a grid: the three columns are evenly spaced, so the gap
      // between 1→2 equals the gap between 2→3. `spaceBetween` on a row of
      // fixed-width keys does NOT give this on a wide screen.
      final one = tester.getRect(find.text('۱')).center;
      final two = tester.getRect(find.text('۲')).center;
      final three = tester.getRect(find.text('۳')).center;
      expect((two.dx - one.dx) - (three.dx - two.dx), closeTo(0, 0.5));

      // The keypad does not stretch to the screen edges on a wide screen.
      expect(three.dx - one.dx, lessThanOrEqualTo(320));
    });
  }

  testWidgets('pressing keys transmits the tone and shows what was typed',
      (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);
    await openKeypad(tester);

    for (final digit in const ['۱', '۲', '۳']) {
      await tester.tap(find.text(digit));
      await tester.pumpAndSettle();
    }
    verify(() => callService.startDtmf('1')).called(1);
    verify(() => callService.startDtmf('2')).called(1);
    verify(() => callService.startDtmf('3')).called(1);
    // Every press is released.
    verify(() => callService.stopDtmf()).called(3);
    // The readout shows the tones sent so far — «۱۲۳», not a key label.
    expect(find.text('۱۲۳'), findsOneWidget);
  });

  testWidgets('the tone is held while the key is down and stopped on release',
      (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);
    await openKeypad(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('۵')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    verify(() => callService.startDtmf('5')).called(1);
    verifyNever(() => callService.stopDtmf());

    await gesture.up();
    await tester.pump();
    verify(() => callService.stopDtmf()).called(1);
  });

  testWidgets('a press that slides a little still types (no tap slop)',
      (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);
    await openKeypad(tester);

    // A thumb that travels 30 px during the press: an `InkWell.onTap` rejects
    // this as a drag, which is how presses used to go missing.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('۸')),
    );
    await gesture.moveBy(const Offset(0, 30));
    await gesture.up();
    await tester.pump();
    verify(() => callService.startDtmf('8')).called(1);
    expect(find.text('۸'), findsWidgets);
    expect(bloc.state.dtmfDigits, '8');
  });

  testWidgets('typed tones survive closing and reopening the keypad',
      (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);
    await openKeypad(tester);
    for (final digit in const ['۴', '۲']) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    await tester.tap(find.text('بستن'));
    await tester.pumpAndSettle();
    await openKeypad(tester);

    expect(find.text('۴۲'), findsOneWidget);
    await tester.tap(find.text('۱'));
    await tester.pump();
    expect(find.text('۴۲۱'), findsOneWidget);
  });

  testWidgets('typed tones survive the call screen being re-pushed',
      (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);
    await openKeypad(tester);
    await tester.tap(find.text('۷'));
    await tester.pump();

    // CallUiCoordinator minimizes / restores by building a NEW InCallScreen.
    await tester.pumpWidget(
      BlocProvider<DialerBloc>.value(
        value: bloc,
        child: const MaterialApp(
          home: InCallScreen(
            key: ValueKey('restored'),
            phone: '09121234567',
            contactName: 'علی رودی',
          ),
        ),
      ),
    );
    await tester.pump();
    await openKeypad(tester);
    expect(find.text('۷'), findsWidgets);
    expect(bloc.state.dtmfDigits, '7');
  });

  testWidgets('the caller stays on screen above the keypad', (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);
    await openKeypad(tester);

    final name = tester.getRect(find.text('علی رودی'));
    expect(name.bottom, lessThan(tester.getRect(find.text('۱')).top));
  });

  testWidgets('a key held when the call ends is released', (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);
    await openKeypad(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('۳')),
    );
    await tester.pump();
    verify(() => callService.startDtmf('3')).called(1);

    events.add(
      const CallInfo(
        event: NativeCallEvent.disconnected,
        phone: '09121234567',
        direction: 'outgoing',
      ),
    );
    await tester.pump();
    await tester.pump();
    verify(() => callService.stopDtmf()).called(1);
    await gesture.up();
    // Tones belong to the call that ended.
    expect(bloc.state.dtmfDigits, isEmpty);
  });

  testWidgets('«بستن» returns to the call screen, and so does back',
      (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);

    await openKeypad(tester);
    expect(find.text('بی‌صدا'), findsNothing);
    await tester.tap(find.text('بستن'));
    await tester.pumpAndSettle();
    expect(find.text('بی‌صدا'), findsOneWidget, reason: 'controls are back');

    await openKeypad(tester);
    expect(find.text('بی‌صدا'), findsNothing);
    // Back closes the keypad before it minimizes the call.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('بی‌صدا'), findsOneWidget);
  });

  testWidgets('a busy call shows the redial countdown, and «لغو» stops it',
      (tester) async {
    AutoRedialPolicy.enabled = true;
    AutoRedialPolicy.maxAttempts = 2;
    addTearDown(() {
      AutoRedialPolicy.enabled = false;
      AutoRedialPolicy.maxAttempts = AutoRedialPolicy.defaultAttempts;
    });
    when(
      () => callService.makeCall(
        any(),
        subscriptionId: any(named: 'subscriptionId'),
      ),
    ).thenAnswer((_) async {});

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final bloc = DialerBloc(repo, callService: callService);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      BlocProvider<DialerBloc>.value(
        value: bloc,
        child: const MaterialApp(home: InCallScreen(phone: '09121234567')),
      ),
    );
    events.add(
      const CallInfo(event: NativeCallEvent.ringing, phone: '09121234567'),
    );
    await tester.pump();
    events.add(
      const CallInfo(
        event: NativeCallEvent.disconnected,
        phone: '09121234567',
        disconnectCause: CallDisconnectCause.busy,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('تماس مجدد خودکار تا'), findsOneWidget);
    expect(find.text('تلاش ۱ از ۲'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.phone_disabled));
    await tester.pump();
    expect(bloc.state.autoRedial, isNull);
    // Well past the countdown: nothing may be dialled after «لغو».
    await tester.pump(const Duration(seconds: 6));
    verifyNever(
      () => callService.makeCall(
        any(),
        subscriptionId: any(named: 'subscriptionId'),
      ),
    );
  });

  testWidgets('the keypad drops away when the call ends', (tester) async {
    final bloc = await pumpCall(tester, const Size(1080, 2400));
    addTearDown(bloc.close);
    await openKeypad(tester);

    events.add(
      const CallInfo(
        event: NativeCallEvent.disconnected,
        phone: '09121234567',
        direction: 'outgoing',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('تماس پایان یافت'), findsOneWidget);
  });
}
