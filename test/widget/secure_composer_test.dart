import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:communication_super_app/features/secure_sms/bloc/secure_messages_bloc.dart';
import 'package:communication_super_app/features/secure_sms/screens/secure_conversation_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The composer of «پیام‌های رمز»: the mentor's emoji report (item 1) and
/// the card a message leaves on (item 6).
void main() {
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

  tearDown(
    () => SimService.debugSetRoster(
      const [],
      defaults: const SimDefaults.unknown(),
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    SimCard? sim,
    VoidCallback? onPickSim,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SecureComposer(
            controller: TextEditingController(),
            plain: false,
            expiry: SecureExpiry.none,
            onExpiry: (_) {},
            onSend: () {},
            sim: () => sim,
            onPickSim: onPickSim,
          ),
        ),
      ),
    ),
  );

  testWidgets('the field is not a password field: emoji and Persian type', (
    tester,
  ) async {
    await pump(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    // `enableSuggestions: false` is TYPE_TEXT_VARIATION_VISIBLE_PASSWORD on
    // Android: a Latin-only keyboard with no emoji key, and a key-event path
    // that keeps half of each emoji.
    expect(field.enableSuggestions, isTrue);
    expect(field.keyboardType, isNot(TextInputType.visiblePassword));
    expect(field.obscureText, isFalse);
    // What the keyboard must still not do with an encrypted text.
    expect(field.enableIMEPersonalizedLearning, isFalse);
    expect(field.autocorrect, isFalse);
  });

  testWidgets('dual-SIM: the card is named before sending, and tappable', (
    tester,
  ) async {
    SimService.debugSetRoster(const [
      sim1,
      sim2,
    ], defaults: const SimDefaults(sms: 10, voice: -1, data: -1));
    var picked = 0;
    await pump(tester, sim: sim2, onPickSim: () => picked++);

    expect(find.byType(SimChip), findsOneWidget);
    expect(find.text('سیم ۲'), findsOneWidget);
    await tester.tap(find.byType(SimChip));
    expect(picked, 1);
  });

  testWidgets('single-SIM: no chip at all', (tester) async {
    SimService.debugSetRoster(const [
      sim1,
    ], defaults: const SimDefaults(sms: 10, voice: -1, data: -1));
    await pump(tester, sim: sim1, onPickSim: () {});
    expect(find.text('سیم ۱'), findsNothing);
  });

  group('a conversation over the menu', () {
    const state = SecureMessagesState(
      smsSim: 10,
      cover: 'fa',
      threadSims: {'09122222222': 13},
      threadCovers: {'09122222222': 'off', '09123333333': 'en'},
    );

    test('its own card, else the menu\'s', () {
      expect(state.simFor('09122222222'), 13);
      expect(state.simFor('09124444444'), 10);
      expect(state.simFor(null), 10);
    });

    test('its own cover text — «خاموش» included — else the menu\'s', () {
      expect(state.coverFor('09122222222'), isNull);
      expect(state.coverFor('09123333333'), 'en');
      expect(state.coverFor('09124444444'), 'fa');
    });
  });
}
