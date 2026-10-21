import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lockout line counts down by itself and is gone when the wait is over;
/// it used to keep the number it was written with.
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('a lockout counts down and disappears', (tester) async {
    await tester.pumpWidget(
      host(
        PinErrorText(
          lockedUntil: DateTime.now().add(const Duration(milliseconds: 1500)),
        ),
      ),
    );
    expect(find.textContaining('۲ ثانیه'), findsOneWidget);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('۱ ثانیه'), findsOneWidget);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 700)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('ثانیه'), findsNothing);
  });

  testWidgets('a plain message is shown as given', (tester) async {
    await tester.pumpWidget(
      host(const PinErrorText(message: 'رمز عبور اشتباه است')),
    );
    expect(find.text('رمز عبور اشتباه است'), findsOneWidget);
  });
}
