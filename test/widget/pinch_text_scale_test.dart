import 'package:communication_super_app/core/utils/message_text_scale.dart';
import 'package:communication_super_app/features/messages/screens/widgets/pinch_text_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The conversation's pinch-to-resize, and the one thing about it that is
/// load-bearing: **one finger belongs to the list.**
///
/// `ScaleGestureRecognizer` treats a one-finger drag as a pan and claims the
/// gesture arena for it, which would take the message list's scroll — the
/// primary interaction on the screen — in exchange for a gesture nobody made.
/// `_PinchOnlyScaleRecognizer` swallows that acceptance while staying alive, so
/// a second finger landing a moment later still starts a real pinch.
///
/// That behaviour could only be checked with two fingers on the glass until
/// now; `WidgetTester` can hold two pointers, so it is checked here instead.
void main() {
  /// A scrollable list under a [PinchTextScale], plus the scale it last
  /// reported.
  Widget harness({
    required ScrollController controller,
    required void Function(double) onScaleChanged,
    double scale = MessageTextScale.normal,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PinchTextScale(
          scale: scale,
          onScaleChanged: onScaleChanged,
          child: ListView.builder(
            controller: controller,
            itemCount: 60,
            itemBuilder: (_, i) => SizedBox(
              height: 60,
              child: Text('row $i'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('one finger scrolls the list and never scales', (tester) async {
    final controller = ScrollController();
    final reported = <double>[];
    await tester.pumpWidget(
      harness(controller: controller, onScaleChanged: reported.add),
    );

    final gesture = await tester.startGesture(const Offset(200, 400));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      greaterThan(0),
      reason: 'the list must still own a one-finger drag',
    );
    expect(reported, isEmpty, reason: 'a single finger is never a pinch');
  });

  testWidgets('two fingers moving apart raise the scale', (tester) async {
    final controller = ScrollController();
    final reported = <double>[];
    await tester.pumpWidget(
      harness(controller: controller, onScaleChanged: reported.add),
    );

    // Two pointers, 100px apart, spreading to 400px — a 4x span.
    final a = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(250, 400), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-15, 0));
      await b.moveBy(const Offset(15, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(reported, isNotEmpty, reason: 'a two-finger spread is a pinch');
    expect(reported.last, greaterThan(MessageTextScale.normal));
    expect(
      MessageTextScale.steps,
      contains(reported.last),
      reason: 'the gesture settles onto an offered size, like the slider',
    );
  });

  testWidgets('two fingers moving together lower the scale', (tester) async {
    final controller = ScrollController();
    final reported = <double>[];
    await tester.pumpWidget(
      harness(
        controller: controller,
        onScaleChanged: reported.add,
        scale: MessageTextScale.steps.last,
      ),
    );

    final a = await tester.startGesture(const Offset(50, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(350, 400), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(13, 0));
      await b.moveBy(const Offset(-13, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(reported, isNotEmpty);
    expect(reported.last, lessThan(MessageTextScale.steps.last));
  });

  testWidgets('a second finger arriving late still starts a pinch', (
    tester,
  ) async {
    // The reason acceptance is *swallowed* rather than rejected: rejecting
    // would kill the recognizer for the rest of the gesture, so a pinch that
    // begins as one finger could never become one.
    final controller = ScrollController();
    final reported = <double>[];
    await tester.pumpWidget(
      harness(controller: controller, onScaleChanged: reported.add),
    );

    final a = await tester.startGesture(const Offset(200, 400), pointer: 1);
    await tester.pump(const Duration(milliseconds: 80));
    final b = await tester.startGesture(const Offset(230, 400), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await a.moveBy(const Offset(-15, 0));
      await b.moveBy(const Offset(15, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(
      reported,
      isNotEmpty,
      reason: 'the recognizer must survive the one-finger phase',
    );
  });
}
