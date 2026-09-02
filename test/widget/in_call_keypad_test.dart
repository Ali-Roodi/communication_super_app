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
    when(() => callService.sendDtmf(any())).thenAnswer((_) async {});
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
    verify(() => callService.sendDtmf('1')).called(1);
    verify(() => callService.sendDtmf('2')).called(1);
    verify(() => callService.sendDtmf('3')).called(1);
    // The readout shows the tones sent so far — «۱۲۳», not a key label.
    expect(find.text('۱۲۳'), findsOneWidget);
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
