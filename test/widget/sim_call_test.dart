import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/call_icon_button.dart';
import 'package:communication_super_app/features/settings/screens/sim_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which card a dial goes out on: a card picked for this one call, else the
/// contact's own card, else the app's default (Settings → «سیم‌کارت‌ها»),
/// else the phone's default, else a question. Everything but the pick and the
/// question is routed natively (`SimRegistry.routeFor`) — the Dart side then
/// names no card at all, so a call follows the phone's own setting exactly.
/// Reported from the field: a phone pinned to SIM 2 dialled on SIM 1, because
/// the app passed the pinned card back to telecom as an explicit account on a
/// build where the two defaults disagreed.
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
  const callChannel = MethodChannel('com.example.communication_super_app/call');

  /// The native side's answer to `callRoute`, as `SimRegistry.routeFor` would
  /// give it. Null = the channel fails.
  late Map<String, Object?>? route;
  late List<int> dialled;
  late Map<String, Object?> mirrored;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    route = {'route': 'phone_default', 'subscriptionId': sim1.subscriptionId};
    dialled = [];
    mirrored = {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(simChannel, (call) async {
      switch (call.method) {
        case 'getDefaults':
          return {'sms': 10, 'voice': 10, 'data': 10, 'voicePinned': true};
        case 'callRoute':
          if (route == null) throw PlatformException(code: 'SIM_ERROR');
          return route;
        case 'setAppDefaults':
          mirrored = Map<String, Object?>.from(call.arguments as Map);
          return null;
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
    SimService.debugSetRoster(const [
      sim1,
      sim2,
    ], defaults: const SimDefaults(sms: 10, voice: 10, data: 10));
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

  testWidgets('with a default, the call names no card and nothing asks — '
      'not even the line a call in «اخیر» came in on', (tester) async {
    final results = await pumpCaller(tester, suggested: sim2);
    await tester.tap(find.text('dial'));
    await tester.pumpAndSettle();
    expect(find.text('تماس با کدام سیم‌کارت؟'), findsNothing);
    expect(dialled, [-1]); // routed natively: the phone's own default
    expect(results, [true]);
  });

  testWidgets('a contact\'s own card is routed natively too', (tester) async {
    route = {'route': 'contact', 'subscriptionId': sim2.subscriptionId};
    await pumpCaller(tester);
    await tester.tap(find.text('dial'));
    await tester.pumpAndSettle();
    expect(find.text('تماس با کدام سیم‌کارت؟'), findsNothing);
    expect(dialled, [-1]);
  });

  testWidgets('«ask every time»: the picker opens on the row\'s card and the '
      'pick is dialled explicitly', (tester) async {
    route = {'route': 'ask', 'subscriptionId': -1};
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

  testWidgets('a route that cannot be read asks rather than guessing', (
    tester,
  ) async {
    route = null;
    await pumpCaller(tester);
    await tester.tap(find.text('dial'));
    await tester.pumpAndSettle();
    expect(find.text('تماس با کدام سیم‌کارت؟'), findsOneWidget);
  });

  testWidgets('holding a call button opens the SIM picker, not a tooltip, '
      'on the card a plain tap would use', (tester) async {
    route = {'route': 'phone_default', 'subscriptionId': sim1.subscriptionId};
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
    final checked = find.ancestor(
      of: find.byIcon(Icons.check_circle),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: checked, matching: find.text('سیم ۱ · Irancell')),
      findsOneWidget,
    );
    await tester.tap(find.text('سیم ۲ · Irancell'));
    await tester.pumpAndSettle();
    expect(dialled, [sim2.subscriptionId]);

    // A plain tap still follows the ordinary rules.
    await tester.tap(find.byType(CallIconButton));
    await tester.pumpAndSettle();
    expect(dialled, [sim2.subscriptionId, -1]);
  });

  testWidgets('dismissing the picker cancels the call', (tester) async {
    route = {'route': 'ask', 'subscriptionId': -1};
    final results = await pumpCaller(tester);
    await tester.tap(find.text('dial'));
    await tester.pumpAndSettle();
    expect(find.text('تماس با کدام سیم‌کارت؟'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // outside the sheet
    await tester.pumpAndSettle();
    expect(dialled, isEmpty);
    expect(results, [false]);
  });

  group('the app\'s own default («سیم‌کارت‌ها»)', () {
    test('starts out following the phone, and says which card that is', () {
      expect(SimService.appDefault(SimUse.voice), SimService.appFollowPhone);
      expect(SimService.defaultFor(SimUse.sms), sim1);
      expect(
        SimSettingsPage.summaryFor(SimUse.sms),
        'پیش‌فرض گوشی · سیم ۱ · Irancell',
      );
    });

    test(
      'a chosen card wins over the phone\'s, is stored and mirrored',
      () async {
        await SimService.instance.setAppDefault(
          SimUse.sms,
          sim2.subscriptionId,
        );
        expect(SimService.defaultFor(SimUse.sms), sim2);
        expect(SimSettingsPage.summaryFor(SimUse.sms), 'سیم ۲ · Irancell');
        expect(mirrored['sms'], sim2.subscriptionId);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('sim_default_sms'), sim2.subscriptionId);

        await SimService.instance.setAppDefault(
          SimUse.voice,
          SimService.appAsk,
        );
        expect(SimService.defaultFor(SimUse.voice), isNull);
        expect(SimSettingsPage.summaryFor(SimUse.voice), 'هر بار بپرس');
        expect(mirrored['voice'], SimService.appAsk);

        // SMS has no «ask»: a conversation always names its card.
        await SimService.instance.setAppDefault(SimUse.sms, SimService.appAsk);
        expect(SimService.appDefault(SimUse.sms), sim2.subscriptionId);

        // A card no longer in the phone reads as "follow the phone".
        await SimService.instance.setAppDefault(SimUse.sms, 99);
        expect(SimService.defaultFor(SimUse.sms), sim1);

        await SimService.instance.setAppDefault(
          SimUse.sms,
          SimService.appFollowPhone,
        );
        await SimService.instance.setAppDefault(
          SimUse.voice,
          SimService.appFollowPhone,
        );
      },
    );
  });
}
