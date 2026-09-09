import 'package:communication_super_app/core/utils/message_text_scale.dart';
import 'package:communication_super_app/features/messages/screens/widgets/pinch_text_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The conversation's pinch-to-resize, and the two things about it that are
/// load-bearing: **one finger belongs to the list**, and **the second finger
/// may arrive whenever it likes**.
///
/// The second one is what was reported — «حتما باید انگشت‌ها همزمان روی صفحه
/// باشه» — and it is why this is a raw `Listener` rather than a
/// `ScaleGestureRecognizer`: once the list's drag recognizer has won the arena
/// it rejects every other member, and rejection stops the loser tracking that
/// pointer, so a scale recognizer can never see two fingers again. See the
/// class doc on `PinchTextScale`.
void main() {
  /// A scrollable list under a [PinchTextScale], wired the way the conversation
  /// wires it: the list stops scrolling while a pinch owns the screen.
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
          child: Builder(
            builder: (context) => ListView.builder(
              controller: controller,
              physics: PinchScope.isPinching(context)
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemCount: 60,
              itemBuilder: (_, i) => SizedBox(
                height: 60,
                child: Text('row $i'),
              ),
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

  // The reported bug, exactly: the first finger is *already scrolling* when the
  // second lands. That is the case the arena could not recover from — the list's
  // drag recognizer has accepted, every other member has been rejected and has
  // stopped tracking, so nothing but simultaneous fingers ever pinched.
  testWidgets('a second finger lands mid-scroll and still pinches', (
    tester,
  ) async {
    final controller = ScrollController();
    final reported = <double>[];
    await tester.pumpWidget(
      harness(controller: controller, onScaleChanged: reported.add),
    );

    final a = await tester.startGesture(const Offset(200, 400), pointer: 1);
    // Enough movement to take the list past touch slop and start a real drag.
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      controller.offset,
      greaterThan(0),
      reason: 'the list must genuinely be scrolling before the second finger',
    );
    final scrolledTo = controller.offset;

    final b = await tester.startGesture(const Offset(230, 400), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await a.moveBy(const Offset(-15, 0));
      await b.moveBy(const Offset(15, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(
      reported,
      isNotEmpty,
      reason: 'a pinch begun mid-scroll must still resize the text',
    );
    expect(reported.last, greaterThan(MessageTextScale.normal));
    expect(
      controller.offset,
      scrolledTo,
      reason: 'the thread must not scroll while the pinch owns the screen',
    );
  });

  testWidgets('a small spread is enough to reach the next size', (
    tester,
  ) async {
    // «sensitivity زوم با ۲ انگشت رو یکم بیشتر کن»: the raw finger ratio needed
    // a 15 % spread for one step. A ~10 % spread must now be enough, and must
    // still land on an offered size rather than overshooting the range.
    final controller = ScrollController();
    final reported = <double>[];
    await tester.pumpWidget(
      harness(controller: controller, onScaleChanged: reported.add),
    );

    // 200px apart, spread to 220px — 10 %.
    final a = await tester.startGesture(const Offset(100, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(300, 400), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-1, 0));
      await b.moveBy(const Offset(1, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(reported, isNotEmpty);
    expect(reported.last, greaterThan(MessageTextScale.normal));
    expect(MessageTextScale.steps, contains(reported.last));
  });
}
