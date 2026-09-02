import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/core/widgets/caret_line_fix.dart';

/// [CaretLineFix] guards the caret against landing on the wrong line when the
/// user taps at the visual start of a soft-wrapped RTL line.
///
/// The assertions are about where the caret is **drawn**, not about the text
/// offset: at a soft wrap the offset is the same on both sides of the break,
/// which is exactly what makes this bug easy to miss.
///
/// Note what these tests can and cannot prove. The mis-placement reproduces on
/// the device (real Persian shaping, real line breaking) and not under the test
/// font, so what is pinned here is the other, equally important half: that the
/// widget is **inert** — every tap that was already right stays right, and
/// typing is never second-guessed.
void main() {
  _dragTests();

  const text =
      'سلام این یک پیام آزمایشی بسیار طولانی است که برای بررسی جایگاه مکان '
      'نما در ابتدای خط دوم و سوم نوشته شده است';

  Future<RenderEditable> pumpField(
    WidgetTester tester,
    TextEditingController controller, {
    required bool withFix,
  }) async {
    final field = TextField(
      controller: controller,
      minLines: 1,
      maxLines: 10,
      style: const TextStyle(fontSize: 16, height: 1.45),
      decoration: const InputDecoration(
        isDense: true,
        filled: false,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                child: withFix
                    ? CaretLineFix(controller: controller, child: field)
                    : field,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
  }

  /// Taps every line at a range of x offsets around its visual start and
  /// returns the lines the caret was drawn on, keyed by the line tapped.
  Future<List<String>> sweep(
    WidgetTester tester,
    TextEditingController controller,
    RenderEditable editable,
  ) async {
    final lh = editable.preferredLineHeight;
    final topLeft = tester.getTopLeft(find.byType(EditableText));
    final lines = (editable.size.height / lh).round();
    // The first tap on an unfocused field only focuses it.
    await tester.tapAt(
      Offset(topLeft.dx + editable.size.width / 2, topLeft.dy + lh * 0.5),
    );
    await tester.pumpAndSettle();

    final wrong = <String>[];
    for (var line = 0; line < lines; line++) {
      final y = topLeft.dy + lh * (line + 0.5);
      // The visual start of an RTL line is its right edge; a fingertip aiming
      // there straddles the edge of the text box, which is where the device
      // used to answer with the line above.
      for (final dx in <double>[-40, -2, 0, 2, 6]) {
        await tester.tapAt(
          Offset(topLeft.dx + editable.size.width + dx, y),
        );
        await tester.pumpAndSettle();
        final selection = controller.selection;
        if (!selection.isCollapsed) continue;
        final rect = editable.getLocalRectForCaret(
          TextPosition(
            offset: selection.baseOffset,
            affinity: selection.affinity,
          ),
        );
        final drawn = (rect.top / lh).round();
        if (drawn != line) wrong.add('line $line at edge+$dx drew on $drawn');
      }
    }
    return wrong;
  }

  testWidgets('a tap at the visual start of a wrapped line stays on that line',
      (tester) async {
    final controller = TextEditingController(text: text);
    final editable = await pumpField(tester, controller, withFix: true);
    expect(
      (editable.size.height / editable.preferredLineHeight).round(),
      greaterThan(2),
      reason: 'the text must actually wrap for this to test anything',
    );
    expect(await sweep(tester, controller, editable), isEmpty);
  });

  testWidgets('the widget is inert where the platform is already right',
      (tester) async {
    // Same sweep without the widget: whatever the platform does here, the
    // wrapped version must do exactly the same. This is the guard against the
    // fix "helping" in cases that were never broken.
    final bare = TextEditingController(text: text);
    final bareEditable = await pumpField(tester, bare, withFix: false);
    final without = await sweep(tester, bare, bareEditable);

    final fixed = TextEditingController(text: text);
    final fixedEditable = await pumpField(tester, fixed, withFix: true);
    final with_ = await sweep(tester, fixed, fixedEditable);

    // The fix may only ever remove entries, never add one.
    expect(with_.toSet().difference(without.toSet()), isEmpty);
  });

  testWidgets('typing is never second-guessed', (tester) async {
    final controller = TextEditingController();
    await pumpField(tester, controller, withFix: true);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
    expect(controller.text, text);
    expect(controller.selection.baseOffset, text.length);
  });
}

/// The failure the device actually reported: dragging the caret handle, not
/// tapping.
///
/// A `logcat` trace of the real composer showed `tap=false` on every caret
/// movement and, at a soft-wrap boundary, this:
///
/// ```
/// sel=75 aff=upstream  down=2@201  up=1@17
/// ```
///
/// One offset, two legitimate carets — the start of line 2 at the right edge,
/// or the end of line 1 at the far left — and the platform picked the second
/// while the user was walking along line 2. These pin the rule that settles it:
/// at such a boundary the caret stays on the line it was already on.
void _dragTests() {
  const text =
      'سلام این یک پیام آزمایشی بسیار طولانی است که برای بررسی جایگاه مکان '
      'نما در ابتدای خط دوم و سوم نوشته شده است و باید در چند خط بشکند';

  testWidgets('a caret walking a line stays on it at the wrap boundary',
      (tester) async {
    final controller = TextEditingController(text: text);
    late RenderEditable editable;
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                child: CaretLineFix(
                  controller: controller,
                  child: TextField(
                    controller: controller,
                    maxLines: 10,
                    style: const TextStyle(fontSize: 16, height: 1.45),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final lh = editable.preferredLineHeight;

    int lineOf(TextSelection s) => (editable
            .getLocalRectForCaret(
              TextPosition(offset: s.baseOffset, affinity: s.affinity),
            )
            .top /
        lh)
        .round();

    // Find a soft-wrap boundary: one offset whose two affinities sit on
    // different lines.
    var boundary = -1;
    for (var i = 1; i < text.length; i++) {
      final d = editable.getLocalRectForCaret(TextPosition(offset: i));
      final u = editable.getLocalRectForCaret(
        TextPosition(offset: i, affinity: TextAffinity.upstream),
      );
      if ((d.top - u.top).abs() > 1) {
        boundary = i;
        break;
      }
    }
    expect(boundary, greaterThan(0), reason: 'the text must soft-wrap');

    // Walk onto the boundary from the *later* line, the way a rightward drag
    // does in RTL, and land on it with the platform's wrong affinity.
    controller.selection = TextSelection.collapsed(offset: boundary + 1);
    await tester.pump();
    final walkingLine = lineOf(controller.selection);

    controller.selection = TextSelection.collapsed(
      offset: boundary,
      affinity: TextAffinity.upstream,
    );
    await tester.pump();

    expect(
      lineOf(controller.selection),
      walkingLine,
      reason: 'the caret jumped to another line while its offset moved by one',
    );
  });

  testWidgets('crossing to the previous line still works', (tester) async {
    final controller = TextEditingController(text: text);
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                child: CaretLineFix(
                  controller: controller,
                  child: TextField(
                    controller: controller,
                    maxLines: 10,
                    style: const TextStyle(fontSize: 16, height: 1.45),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final lh = editable.preferredLineHeight;

    var boundary = -1;
    for (var i = 1; i < text.length; i++) {
      final d = editable.getLocalRectForCaret(TextPosition(offset: i));
      final u = editable.getLocalRectForCaret(
        TextPosition(offset: i, affinity: TextAffinity.upstream),
      );
      if ((d.top - u.top).abs() > 1) {
        boundary = i;
        break;
      }
    }

    controller.selection = TextSelection.collapsed(offset: boundary + 1);
    await tester.pump();
    controller.selection = TextSelection.collapsed(offset: boundary);
    await tester.pump();
    // One more character back is unambiguously the previous line — continuity
    // must not hold the caret hostage.
    controller.selection = TextSelection.collapsed(offset: boundary - 1);
    await tester.pump();

    final rect = editable.getLocalRectForCaret(
      TextPosition(
        offset: controller.selection.baseOffset,
        affinity: controller.selection.affinity,
      ),
    );
    expect((rect.top / lh).round(), lessThan(
      (editable
                  .getLocalRectForCaret(TextPosition(offset: boundary + 1))
                  .top /
              lh)
          .round(),
    ));
  });
}
