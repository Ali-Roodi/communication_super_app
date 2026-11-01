import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_bubble.dart';
import 'package:communication_super_app/features/settings/screens/sim_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Matrix row 5: a card's name — given in the app, else the operator's — is
/// what the call and send buttons carry.
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
    displayName: 'IR-MCI',
    carrierName: 'MCI',
    number: '',
  );
  const simChannel = MethodChannel('com.example.communication_super_app/sim');

  group('SimCard', () {
    test('the name given in the app comes first', () {
      expect(sim1.name, 'Irancell');
      const named = SimCard(
        subscriptionId: 10,
        slotIndex: 0,
        displayName: 'Irancell',
        carrierName: 'Irancell',
        number: '',
        customName: 'کاری',
      );
      expect(named.name, 'کاری');
      expect(named.operatorName, 'Irancell');
      // The operator moves to the second line once the card has a name.
      expect(named.subtitle, 'Irancell');
      expect(sim1.subtitle, isNull);
    });

    test('falls back to the operator, then the slot', () {
      const blank = SimCard(
        subscriptionId: 1,
        slotIndex: 1,
        displayName: ' ',
        carrierName: '',
        number: '',
      );
      expect(blank.name, 'سیم ۲');
      expect(sim2.name, 'IR-MCI');
    });

    test('reads the name from the roster, trimmed', () {
      final card = SimCard.fromMap({
        'subscriptionId': 10,
        'slotIndex': 0,
        'displayName': 'Irancell',
        'carrierName': 'Irancell',
        'customName': '  شخصی ',
      });
      expect(card.customName, 'شخصی');
      expect(card.name, 'شخصی');
      expect(SimCard.fromMap({'subscriptionId': 10}).customName, '');
    });
  });

  testWidgets('the send button carries the name it is given', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MessageSendButton(
              enabled: true,
              onSend: () => sent++,
              simName: 'کاری',
            ),
          ),
        ),
      ),
    );
    expect(find.text('کاری'), findsOneWidget);
    await tester.tap(find.text('کاری'));
    expect(sent, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageSendButton(enabled: true, onSend: () {})),
      ),
    );
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('the composer chip shows the SIM icon and only the slot number', (tester) async {
    SimService.debugSetRoster(const [sim1, sim2]);
    addTearDown(() => SimService.debugSetRoster(const []));
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SimChip(sim: sim2, onTap: () => taps++, numberOnly: true),
          ),
        ),
      ),
    );
    expect(find.text('۲'), findsOneWidget);
    expect(find.text('سیم ۲'), findsNothing);
    expect(find.byIcon(Icons.sim_card_outlined), findsOneWidget);
    expect(find.bySemanticsLabel('ارسال با سیم ۲، IR-MCI'), findsOneWidget);
    await tester.tap(find.text('۲'));
    expect(taps, 1);
  });

  group('Settings → سیم‌کارت‌ها', () {
    late List<Map<String, Object?>> named;
    late Map<int, String> stored;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      named = [];
      stored = {};
      SimService.debugSetRoster(const [sim1, sim2]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(simChannel, (call) async {
            switch (call.method) {
              case 'setSimName':
                final args = Map<String, Object?>.from(call.arguments as Map);
                named.add(args);
                final name = args['name'] as String;
                final id = args['subscriptionId'] as int;
                name.isEmpty ? stored.remove(id) : stored[id] = name;
                return null;
              case 'getSubscriptions':
                return [
                  for (final sim in [sim1, sim2])
                    {
                      'subscriptionId': sim.subscriptionId,
                      'slotIndex': sim.slotIndex,
                      'displayName': sim.displayName,
                      'carrierName': sim.carrierName,
                      'number': '',
                      'customName': stored[sim.subscriptionId],
                    },
                ];
              case 'getDefaults':
                return {'sms': 10, 'voice': 10, 'data': 10};
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(simChannel, null);
      SimService.debugSetRoster(const []);
    });

    testWidgets('a card is named and the name can be removed', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: SimSettingsPage()));
      await tester.pumpAndSettle();

      expect(find.text('بدون نام · \u2068Irancell\u2069'), findsOneWidget);
      await tester.tap(find.text('سیم ۱'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  کاری ');
      await tester.tap(find.text('ذخیره'));
      await tester.pumpAndSettle();

      expect(named.single, {'subscriptionId': 10, 'name': 'کاری'});
      expect(SimService.byId(10)!.name, 'کاری');
      expect(
        find.text('\u2068کاری\u2069 · \u2068Irancell\u2069'),
        findsOneWidget,
      );

      await tester.tap(find.text('سیم ۱'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('ذخیره'));
      await tester.pumpAndSettle();

      expect(named.last['name'], '');
      expect(SimService.byId(10)!.name, 'Irancell');
      expect(find.text('بدون نام · \u2068Irancell\u2069'), findsOneWidget);
    });
  });
}
