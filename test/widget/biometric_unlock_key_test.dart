import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import 'package:communication_super_app/features/authentication/services/biometric_unlock.dart';

/// A [BiometricUnlock] that answers from a script and counts the prompts.
class _FakeBiometric extends BiometricUnlock {
  _FakeBiometric({
    required this.enabled,
    this.outcome = BiometricUnlockOutcome.unlocked,
  });

  final bool enabled;
  BiometricUnlockOutcome outcome;
  int prompts = 0;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<BiometricUnlockOutcome> unlock() async {
    prompts++;
    return outcome;
  }
}

void main() {
  setUp(() {
    // The app is in front, as it is when a lock screen is drawn.
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  Widget host(
    _FakeBiometric fake, {
    VoidCallback? onUnlocked,
    ValueChanged<String>? onMessage,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 120,
          child: BiometricUnlockKey(
            service: fake,
            onUnlocked: () async => onUnlocked?.call(),
            onMessage: (m) => onMessage?.call(m),
          ),
        ),
      ),
    ),
  );

  testWidgets('off: an empty slot, and no prompt', (tester) async {
    final fake = _FakeBiometric(enabled: false);
    await tester.pumpWidget(host(fake));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fingerprint), findsNothing);
    expect(fake.prompts, 0);
  });

  testWidgets('on: the key shows and the prompt comes up by itself, once', (
    tester,
  ) async {
    var unlocked = 0;
    final fake = _FakeBiometric(
      enabled: true,
      outcome: BiometricUnlockOutcome.cancelled,
    );
    await tester.pumpWidget(host(fake, onUnlocked: () => unlocked++));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
    expect(fake.prompts, 1);
    expect(unlocked, 0);

    // A resume that was not a trip out (the prompt itself) does not re-prompt.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fake.prompts, 1);

    // The key raises it again.
    fake.outcome = BiometricUnlockOutcome.unlocked;
    await tester.tap(find.byIcon(Icons.fingerprint));
    await tester.pumpAndSettle();
    expect(fake.prompts, 2);
    expect(unlocked, 1);
  });

  testWidgets('a real trip out of the app re-arms the automatic prompt', (
    tester,
  ) async {
    final fake = _FakeBiometric(
      enabled: true,
      outcome: BiometricUnlockOutcome.cancelled,
    );
    await tester.pumpWidget(host(fake));
    await tester.pumpAndSettle();
    expect(fake.prompts, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fake.prompts, 2);
  });

  testWidgets('a changed enrollment hides the key and says why', (
    tester,
  ) async {
    final messages = <String>[];
    final fake = _FakeBiometric(
      enabled: true,
      outcome: BiometricUnlockOutcome.enrollmentChanged,
    );
    await tester.pumpWidget(host(fake, onMessage: messages.add));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fingerprint), findsNothing);
    expect(messages.single, contains('تغییر کرده'));
  });

  testWidgets('no automatic prompt while the lock is not the top route', (
    tester,
  ) async {
    final fake = _FakeBiometric(enabled: true);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: BiometricUnlockKey(
              service: fake,
              onUnlocked: () async {},
              onMessage: (_) {},
            ),
          ),
        ),
      ),
    );
    // A call screen lands on top before the setting has been read.
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(fake.prompts, 0);
  });
}
