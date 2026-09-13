import 'package:flutter/gestures.dart';
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
  _hangingSpaceTests();
  _newlineTests();

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
        await tester.tapAt(Offset(topLeft.dx + editable.size.width + dx, y));
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

  testWidgets(
    'a tap at the visual start of a wrapped line stays on that line',
    (tester) async {
      final controller = TextEditingController(text: text);
      final editable = await pumpField(tester, controller, withFix: true);
      expect(
        (editable.size.height / editable.preferredLineHeight).round(),
        greaterThan(2),
        reason: 'the text must actually wrap for this to test anything',
      );
      expect(await sweep(tester, controller, editable), isEmpty);
    },
  );

  testWidgets('the widget is inert where the platform is already right', (
    tester,
  ) async {
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

/// A wrapped field on the test font, where every glyph is a [fontSize] square
/// so the wrap points are known exactly. Returns the render object so a test
/// can measure which line a caret is drawn on.
Future<RenderEditable> _pumpWrapped(
  WidgetTester tester,
  TextEditingController controller, {
  required double width,
  TextDirection direction = TextDirection.rtl,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: CaretLineFix(
                controller: controller,
                child: TextField(
                  controller: controller,
                  maxLines: 10,
                  style: const TextStyle(fontSize: 16, height: 1.45),
                  decoration: const InputDecoration(
                    isDense: true,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                  ),
                ),
              ),
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

int _lineOf(RenderEditable editable, TextSelection s) =>
    (editable
                .getLocalRectForCaret(
                  TextPosition(offset: s.baseOffset, affinity: s.affinity),
                )
                .top /
            editable.preferredLineHeight)
        .round();

/// The first offset whose two affinities draw on different lines — a soft
/// wrap. -1 when the text does not wrap.
int _boundaryOf(RenderEditable editable, String text) {
  for (var i = 1; i < text.length; i++) {
    final d = editable.getLocalRectForCaret(TextPosition(offset: i));
    final u = editable.getLocalRectForCaret(
      TextPosition(offset: i, affinity: TextAffinity.upstream),
    );
    if ((d.top - u.top).abs() > 1) return i;
  }
  return -1;
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
/// while a finger is down, the caret changes line only when the finger moved
/// vertically to ask for it — and, just as important, that a caret moved with
/// **no** finger (an IME's cursor keys) is never held back.
void _dragTests() {
  // Ten 16 px glyphs per 160 px line: wraps after every space, and the word
  // before each wrap ends one glyph short of the edge so the boundary offset
  // is preceded by a space.
  const text = 'aaaa bbbb cccc dddd eeee ffff';

  testWidgets('a dragged caret stays on its line at the wrap boundary', (
    tester,
  ) async {
    final controller = TextEditingController(text: text);
    final editable = await _pumpWrapped(tester, controller, width: 160);
    final boundary = _boundaryOf(editable, text);
    expect(boundary, greaterThan(0), reason: 'the text must soft-wrap');

    // A finger down somewhere (the handle lives in the overlay, so where does
    // not matter) and held there: this is a drag.
    final finger = await tester.startGesture(const Offset(400, 500));
    await tester.pump();

    // Walking along the later line, the platform lands on the boundary with
    // the wrong affinity — the end of the line above.
    controller.selection = TextSelection.collapsed(offset: boundary + 1);
    await tester.pump();
    final walkingLine = _lineOf(editable, controller.selection);
    controller.selection = TextSelection.collapsed(
      offset: boundary,
      affinity: TextAffinity.upstream,
    );
    await tester.pump();

    expect(
      _lineOf(editable, controller.selection),
      walkingLine,
      reason: 'the caret jumped to another line on a sideways nudge',
    );
    await finger.up();
  });

  testWidgets('a vertical drag is allowed to change line', (tester) async {
    final controller = TextEditingController(text: text);
    final editable = await _pumpWrapped(tester, controller, width: 160);
    final boundary = _boundaryOf(editable, text);
    final lh = editable.preferredLineHeight;

    final finger = await tester.startGesture(const Offset(400, 500));
    await tester.pump();
    controller.selection = TextSelection.collapsed(offset: boundary + 1);
    await tester.pump();
    final walkingLine = _lineOf(editable, controller.selection);

    // The finger moves up a full line, then the platform reports a caret on
    // the line above: that is what the finger asked for.
    await finger.moveBy(Offset(0, -lh));
    await tester.pump();
    controller.selection = TextSelection.collapsed(offset: boundary - 2);
    await tester.pump();

    expect(_lineOf(editable, controller.selection), walkingLine - 1);
    await finger.up();
  });

  testWidgets('a caret moved with no finger is never held back', (
    tester,
  ) async {
    // An IME's cursor keys and a hardware keyboard move the caret with no
    // pointer event at all. Continuity must not apply there, or the keyboard
    // could never step across the boundary.
    final controller = TextEditingController(text: text);
    final editable = await _pumpWrapped(tester, controller, width: 160);
    final boundary = _boundaryOf(editable, text);

    controller.selection = TextSelection.collapsed(offset: boundary - 2);
    await tester.pump();
    final startLine = _lineOf(editable, controller.selection);
    controller.selection = TextSelection.collapsed(offset: boundary + 1);
    await tester.pump();

    expect(controller.selection.baseOffset, boundary + 1);
    expect(_lineOf(editable, controller.selection), startLine + 1);
  });
}

/// «آخر یک کلمه توی یک خط کلیک کنی و حرف آخر رو پاک کنی، یک کاراکتر خطا داره
/// و میره اول خط بعدی».
///
/// The space a line wraps at hangs past the line's visible end, and a tap in
/// the empty run after the last word hits it: the platform answers with the
/// offset after the space, drawn at the end of the line exactly where a caret
/// after the last letter would be. Backspace then deletes the space instead of
/// the letter. `EditText` never places that caret; neither may this.
void _hangingSpaceTests() {
  const text = 'aaaa bbbb cccc dddd eeee ffff';

  testWidgets('the caret after a hanging space is stepped back before it', (
    tester,
  ) async {
    final controller = TextEditingController(text: text);
    final editable = await _pumpWrapped(tester, controller, width: 160);
    final boundary = _boundaryOf(editable, text);
    expect(text[boundary - 1], ' ', reason: 'the line must wrap at a space');
    final lineAbove = _lineOf(
      editable,
      TextSelection.collapsed(
        offset: boundary,
        affinity: TextAffinity.upstream,
      ),
    );

    controller.selection = TextSelection.collapsed(
      offset: boundary,
      affinity: TextAffinity.upstream,
    );
    await tester.pump();

    expect(controller.selection.baseOffset, boundary - 1);
    expect(controller.selection.isCollapsed, isTrue);
    // Same line, same visible spot: the correction is invisible until the
    // next backspace, which now removes the letter.
    expect(_lineOf(editable, controller.selection), lineAbove);
  });

  testWidgets('a tap in the gap after the last word lands after that word', (
    tester,
  ) async {
    final controller = TextEditingController(text: text);
    final editable = await _pumpWrapped(
      tester,
      controller,
      width: 160,
      direction: TextDirection.ltr,
    );
    final boundary = _boundaryOf(editable, text);
    final lh = editable.preferredLineHeight;
    final topLeft = tester.getTopLeft(find.byType(EditableText));

    // Focus first: the first tap on an unfocused field only focuses it.
    await tester.tapAt(topLeft + Offset(editable.size.width / 2, lh * 2.5));
    await tester.pumpAndSettle();
    // Taps a few frames apart would read as a double tap and select a word.
    await tester.pump(kDoubleTapTimeout);

    // Latin letters run LTR whatever the paragraph direction, so the mirror
    // image of the Persian composer is an LTR field: line 0 is «aaaa bbbb»,
    // nine glyphs of ten, its visible end at x = 144 and the hanging space
    // at 144..160. Every tap from the middle of that space outwards used to
    // land *after* it.
    final lineAbove = _lineOf(
      editable,
      TextSelection.collapsed(
        offset: boundary,
        affinity: TextAffinity.upstream,
      ),
    );
    for (final x in <double>[159, 156, 153]) {
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      await tester.tapAt(topLeft + Offset(x, lh * (lineAbove + 0.5)));
      await tester.pumpAndSettle();
      await tester.pump(kDoubleTapTimeout);
      expect(
        controller.selection.baseOffset,
        boundary - 1,
        reason: 'tap at x=$x landed after the hanging space',
      );
    }
  });

  testWidgets('the start of the next line is untouched', (tester) async {
    // The same offset with downstream affinity is the start of the next
    // line — a real caret that must stay where it is.
    final controller = TextEditingController(text: text);
    final editable = await _pumpWrapped(tester, controller, width: 160);
    final boundary = _boundaryOf(editable, text);

    controller.selection = TextSelection.collapsed(offset: boundary);
    await tester.pump();

    expect(controller.selection.baseOffset, boundary);
    expect(controller.selection.affinity, TextAffinity.downstream);
  });

  testWidgets('a hard line break is not a hanging space', (tester) async {
    const hard = 'aaaa bbbb \ncccc';
    final controller = TextEditingController(text: hard);
    final editable = await _pumpWrapped(tester, controller, width: 160);
    // After the newline: the start of line 1, and the character before the
    // caret is the newline, not a space.
    controller.selection = const TextSelection.collapsed(
      offset: 11,
      affinity: TextAffinity.upstream,
    );
    await tester.pump();
    expect(controller.selection.baseOffset, 11);
    // Before the newline, after the space: both affinities draw on line 0, so
    // this is an ordinary caret after an ordinary space.
    controller.selection = const TextSelection.collapsed(
      offset: 10,
      affinity: TextAffinity.upstream,
    );
    await tester.pump();
    expect(controller.selection.baseOffset, 10);
    expect(_lineOf(editable, controller.selection), 0);
  });

  testWidgets('the trailing space of the last line is untouched', (
    tester,
  ) async {
    const trailing = 'aaaa bbbb cccc ';
    final controller = TextEditingController(text: trailing);
    await _pumpWrapped(tester, controller, width: 160);
    controller.selection = TextSelection.collapsed(
      offset: trailing.length,
      affinity: TextAffinity.upstream,
    );
    await tester.pump();
    expect(controller.selection.baseOffset, trailing.length);
  });
}

/// The same report, on a message typed with Enter rather than wrapped: a tap
/// in the empty run after the last word of a hard-broken line hits the newline
/// and the platform answers with the offset after it — the start of the next
/// line. Traced on the device as `sel=8 aff=upstream prev=U+000a down=2@203`
/// for a finger on line 1.
///
/// The test font answers these taps correctly by itself, so — like the
/// soft-wrap misplacement — the correction is verified on the device; what
/// is pinned here is that it never makes a right answer wrong.
void _newlineTests() {
  const text = 'aaaa\nbbbbbb\ncc';

  testWidgets(
    'a tap after the last word of a hard-broken line ends that line',
    (tester) async {
      final controller = TextEditingController(text: text);
      final editable = await _pumpWrapped(
        tester,
        controller,
        width: 160,
        direction: TextDirection.ltr,
      );
      final lh = editable.preferredLineHeight;
      final topLeft = tester.getTopLeft(find.byType(EditableText));

      await tester.tapAt(topLeft + Offset(8, lh * 2.5));
      await tester.pumpAndSettle();
      await tester.pump(kDoubleTapTimeout);

      // Line 0 is «aaaa», 64 px wide; the run from there to the edge is empty.
      for (final x in <double>[70, 100, 150]) {
        controller.selection = const TextSelection.collapsed(offset: 13);
        await tester.pump();
        await tester.tapAt(topLeft + Offset(x, lh * 0.5));
        await tester.pumpAndSettle();
        await tester.pump(kDoubleTapTimeout);
        expect(
          controller.selection.baseOffset,
          4,
          reason: 'tap at x=$x did not land at the end of line 0',
        );
      }
      // And on line 1, whose end is offset 11.
      await tester.tapAt(topLeft + Offset(150, lh * 1.5));
      await tester.pumpAndSettle();
      expect(controller.selection.baseOffset, 11);
    },
  );

  testWidgets('a tap at the start of the next line is left there', (
    tester,
  ) async {
    final controller = TextEditingController(text: text);
    final editable = await _pumpWrapped(
      tester,
      controller,
      width: 160,
      direction: TextDirection.ltr,
    );
    final lh = editable.preferredLineHeight;
    final topLeft = tester.getTopLeft(find.byType(EditableText));
    await tester.tapAt(topLeft + Offset(8, lh * 2.5));
    await tester.pumpAndSettle();
    await tester.pump(kDoubleTapTimeout);

    await tester.tapAt(topLeft + Offset(2, lh * 1.5));
    await tester.pumpAndSettle();
    expect(controller.selection.baseOffset, 5);
  });
}
