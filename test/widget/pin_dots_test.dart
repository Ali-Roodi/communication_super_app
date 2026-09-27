import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The dots in on-screen order, left to right, and whether each is filled.
  List<bool> filledLeftToRight(WidgetTester tester) {
    final dots = tester.widgetList<Container>(find.byType(Container)).map((c) {
      final decoration = c.decoration! as BoxDecoration;
      return (
        left: tester.getTopLeft(find.byWidget(c)).dx,
        filled: decoration.color != Colors.transparent,
      );
    }).toList()..sort((a, b) => a.left.compareTo(b.left));
    return dots.map((d) => d.filled).toList();
  }

  Future<void> pumpDots(WidgetTester tester, int filled) {
    return tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          // Every PIN screen is RTL; the dots must not inherit it.
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Center(child: PinDots(filled: filled)),
          ),
        ),
      ),
    );
  }

  testWidgets('the first digit fills the LEFTMOST dot on an RTL page', (
    tester,
  ) async {
    await pumpDots(tester, 1);
    expect(filledLeftToRight(tester), [true, false, false, false]);
  });

  testWidgets('dots fill left to right as digits are typed', (tester) async {
    await pumpDots(tester, 3);
    expect(filledLeftToRight(tester), [true, true, true, false]);
  });
}
