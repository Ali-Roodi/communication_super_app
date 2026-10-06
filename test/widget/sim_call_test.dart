import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/call_icon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which card a plain dial goes out on. Reported from the field: a phone
/// pinned to SIM 1 for calls placed most of its calls on SIM 2 — «اخیر»
/// called back on the line a call had come in on, and the pinned default was
/// read once per process — and the second number was given away.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sim1 = SimCard(
    subscriptionId: 10,
    slotIndex: 0,
    displayName: 'Irancell',
    carrierName: 'Irancell',
    number: '',
  );
  const sim2 = SimCard(
    subscriptionId: 13,
    slotIndex: 1,
    displayName: 'Irancell',
    carrierName: 'Irancell',
    number: '',
  );
  const simChannel = MethodChannel('com.example.communication_super_app/sim');
  const callChannel = MethodChannel(
    'com.example.communication_super_app/call',
  );

  /// What Android's settings say right now.
  late int systemVoice;
  late List<int> dialled;

  setUp(() {
    systemVoice = sim1.subscriptionId;
    dialled = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(simChannel, (call) async {
      if (call.method == 'getDefaults') {
        return {'sms': sim1.subscriptionId, 'voice': systemVoice, 'data': 10};
      }
      return null;
    });
    // The long-press buzzes first; unanswered, that await never returns.
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async {
      return null;
    });
    messenger.setMockMethodCallHandler(callChannel, (call) async {
      if (call.method == 'makeCall') {
        dialled.add((call.arguments as Map)['subscriptionId'] as int);
      }
      return null;
    });
    SimService.debugSetRoster(
      const [sim1, sim2],
      defaults: const SimDefaults(sms: 10, voice: 10, data: 10),
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(simChannel, null);
    messenger.setMockMethodCallHandler(callChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Pumps a button that dials through [placeCall]; returns its result slot.
  Future<List<bool>> pumpCaller(
    WidgetTester tester, {
    SimCard? suggested,
  }) async {
    final results = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(
                await placeCall(context, '09190961805', suggested: suggested),
              ),
              child: const Text('dial'),
            ),
          ),
        ),
      ),
    );
    return results;
  }

  testWidgets('a call-back from «اخیر» uses the pinned SIM, not the line '
      'the call came in on', (tester) async {
    final results = await pumpCaller(tester, suggested: sim2);
    await tester.tap(find.text('dial'));
    await tester.pumpAndSettle();
    expect(find.text('تماس با کدام سیم‌کارت؟'), findsNothing);
    expect(dialled, [sim1.subscriptionId]);
    expect(results, [true]);
  });

  testWidgets('a default re-pinned in Android settings is followed without '
      'a restart', (tester) async {
    systemVoice = sim2.subscriptionId; // changed while the app was alive
    final results = await pumpCaller(tester);
    await tester.tap(find.text('dial'));
    await tester.pumpAndSettle();
    expect(dialled, [sim2.subscriptionId]);
    expect(results, [true]);
  });

  testWidgets('with nothing pinned the picker opens on the row\'s card', (
    tester,
  ) async {
    systemVoice = SimCard.invalidSubscriptionId;
    await pumpCaller(tester, suggested: sim2);
    await tester.tap(find.text('dial'));
    await tester.pumpAndSettle();
    expect(find.text('تماس با کدام سیم‌کارت؟'), findsOneWidget);
    final checked = find.ancestor(
      of: find.byIcon(Icons.check_circle),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: checked, matching: find.text('سیم ۲ · Irancell')),
      findsOneWidget,
    );
    await tester.tap(find.text('سیم ۲ · Irancell'));
    await tester.pumpAndSettle();
    expect(dialled, [sim2.subscriptionId]);
  });

  testWidgets('holding a call button opens the SIM picker, not a tooltip', (
    tester,
  ) async {
    // Android (the test default) is where a tooltip opens on long-press.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: CallIconButton(
                onPressed: () => placeCall(context, '09190961805'),
                onLongPress: () => placeCallPickingSim(context, '09190961805'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.byType(CallIconButton));
    await tester.pumpAndSettle();
    expect(find.text('تماس با کدام سیم‌کارت؟'), findsOneWidget);
    await tester.tap(find.text('سیم ۲ · Irancell'));
    await tester.pumpAndSettle();
    expect(dialled, [sim2.subscriptionId]);

    // A plain tap still goes out on the pinned card.
    await tester.tap(find.byType(CallIconButton));
    await tester.pumpAndSettle();
    expect(dialled, [sim2.subscriptionId, sim1.subscriptionId]);
  });

  testWidgets('dismissing the picker cancels the call, even when the pinned '
      'card is gone', (tester) async {
    systemVoice = 99; // a card no longer in the phone
    final results = await pumpCaller(tester);
    await tester.tap(find.text('dial'));
    await tester.pumpAndSettle();
    expect(find.text('تماس با کدام سیم‌کارت؟'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // outside the sheet
    await tester.pumpAndSettle();
    expect(dialled, isEmpty);
    expect(results, [false]);
  });
}
