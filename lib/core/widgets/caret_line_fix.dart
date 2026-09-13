import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Puts the caret where Android's own `EditText` would have put it, at the
/// two places Flutter's text hit-testing differs from it in a wrapped RTL
/// paragraph. Both were reported from the composer, both reproduce on the
/// device, and both come down to the same fact: a soft wrap gives one text
/// offset **two** legitimate carets — the boundary offset draws at the end of
/// line N with `TextAffinity.upstream` and at the start of line N+1 with
/// `downstream` — and Flutter picks between them from the nearest glyph, not
/// from which line the finger was on.
///
/// ## 1. A tap past the last word of a line lands *after* the trailing space
///
/// «آخر یک کلمه توی یک خط کلیک کنی و حرف آخر رو پاک کنی، یک کاراکتر خطا داره
/// و میره اول خط بعدی». The space that a line wraps at is not drawn — it hangs
/// past the line's visible end — but it is still hit-tested. Tap in the empty
/// run after the last word (anywhere more than a couple of dp past the middle
/// of that invisible space) and the platform answers with the offset **after**
/// the space, drawn at the end of the line with `upstream` affinity. On screen
/// that is indistinguishable from a caret after the last letter. Backspace then
/// deletes the space: the two words join, the joined word no longer fits, the
/// paragraph re-wraps, and the caret comes up at the start of the next line
/// with the letter still there. Traced on the device as
/// `sel=23 aff=upstream down=1@201 up=0@27` for a tap at `finger=(31,12)` —
/// line 0, in the gap.
///
/// Android cannot produce that caret: `Layout.getOffsetForHorizontal` caps
/// every line but the last at the offset *before* its trailing whitespace. The
/// same rule is applied here — see [_beforeHangingSpace] — to every caret the
/// platform places, however it was placed, because a caret after a hanging
/// space is never what anyone meant.
///
/// ## 2. A tap at the visual *start* of a line lands at the end of the one above
///
/// The start of an RTL line is its right edge, which is also the edge of the
/// text box; a fingertip aiming there straddles the edge, and past it the
/// nearest glyph can belong to the line above, so both the affinity and the
/// offset can come back a line out. `EditText` resolves the **line from y
/// first** (`Layout.getLineForVertical`) and only then clamps x inside it;
/// [_correct] restores that after a tap by checking whether the caret ended up
/// on the line the finger was on and, if not, flipping the affinity or
/// re-running the platform's hit test with the touch point pulled inside the
/// box.
///
/// ## Drags
///
/// Walking the caret handle along a line steps one offset at a time, and at
/// the boundary that one step is ambiguous — the device trace showed the caret
/// teleporting from the start of line 2 to the end of line 1 on a sideways
/// nudge. [_clampToDraggedLine] refuses a line change the finger did not ask
/// for: while a finger is down, the caret may only change lines once the finger
/// has moved half a line vertically since the caret last moved. That is
/// `EditText`'s handle-drag rule too (line from the finger's y, x within it).
///
/// ## Why it is safe
///
/// The tap correction only runs when the caret is demonstrably not on the
/// tapped line; the drag clamp only runs while a finger is down; the
/// hanging-space rule only fires for the one caret `EditText` never draws.
/// None of them run for typing (the text changed), for a range selection, or
/// for a caret moved with no pointer at all (an IME's cursor keys, a hardware
/// keyboard) — there the platform's answer is taken as it is, so a keyboard
/// can always step across the boundary.
class CaretLineFix extends StatefulWidget {
  const CaretLineFix({
    super.key,
    required this.controller,
    required this.child,
  });

  /// The controller of the field inside [child]. Its selection is what gets
  /// corrected.
  final TextEditingController controller;

  /// The field. Any subtree with exactly one [EditableText] in it.
  final Widget child;

  @override
  State<CaretLineFix> createState() => _CaretLineFixState();
}

/// How recently the tap must have happened for a selection change to be its
/// doing. Long enough to cover the frame between the finger lifting and the
/// selection landing, short enough that a later caret move is never matched
/// against a stale finger.
const Duration _kPointerWindow = Duration(milliseconds: 700);

/// Movement above which the gesture was a drag, not a tap. Matches
/// [kTouchSlop]'s intent; a handle drag is always well past it.
const double _kTapSlop = 12;

/// Whether the caret path prints its measurements to logcat, tagged `[caret]`.
///
/// Off unless the build was made with `--dart-define=CARET_TRACE=true` — never
/// in a store build, which has no business printing a line per caret movement.
/// It exists because the Persian shaping and line breaking that trigger these
/// bugs do not reproduce under the test font, so the only way to see which
/// line the caret landed on versus which line the finger was on is to run the
/// build on a phone and read `adb logcat -s flutter | grep caret`.
const bool kCaretDebug = bool.fromEnvironment('CARET_TRACE');

class _CaretLineFixState extends State<CaretLineFix> {
  /// Where the last gesture went down and came up, in global coordinates.
  ///
  /// Read from a **global** pointer route rather than a [Listener] around the
  /// child: the caret's drag handle is drawn in the app's [Overlay], outside
  /// this subtree, and this needs to see those events precisely so it can tell
  /// a handle drag from a tap and stay out of the way.
  Offset? _down;
  Offset? _up;
  DateTime? _upAt;

  /// Where the finger is **now**, and where it was when the caret last moved.
  ///
  /// The second is what makes the drag clamp possible: a drag that only moves
  /// sideways must not change lines, and "only sideways" can only be judged
  /// against the finger's position at the previous caret movement.
  Offset? _move;
  Offset? _moveAtLastCaret;

  String? _lastText;

  /// The visual line the caret was drawn on the last time it settled, and the
  /// selection it settled on — what a refused drag step is wound back to.
  int? _lastCaretLine;
  TextSelection? _lastSelection;

  /// Guards the write-back: assigning `controller.selection` notifies the
  /// controller again.
  bool _correcting = false;

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    widget.controller.addListener(_onControllerChanged);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
  }

  @override
  void didUpdateWidget(CaretLineFix oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastText = widget.controller.text;
      _forget();
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onPointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _down = event.position;
      _move = event.position;
      _moveAtLastCaret = null;
      _up = null;
      _upAt = null;
    } else if (event is PointerMoveEvent) {
      _move = event.position;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _up = event.position;
      _upAt = DateTime.now();
      _move = event.position;
    }
  }

  /// True while a finger is down — i.e. the caret is being dragged, not tapped.
  bool get _dragging => _down != null && _up == null;

  /// The point of a gesture that was a **tap**, or null when the last gesture
  /// was a drag, is still running, or is too old to have caused this change.
  Offset? get _tapPoint {
    final down = _down;
    final up = _up;
    final at = _upAt;
    if (down == null || up == null || at == null) return null;
    if ((up - down).distance > _kTapSlop) return null;
    if (DateTime.now().difference(at) > _kPointerWindow) return null;
    return down;
  }

  /// The remembered line means nothing once the text (and so the layout)
  /// changed.
  void _forget() {
    _lastCaretLine = null;
    _lastSelection = null;
  }

  void _onControllerChanged() {
    if (_correcting) return;
    final text = widget.controller.text;
    final textChanged = text != _lastText;
    _lastText = text;
    if (kCaretDebug) _trace(textChanged ? 'typed' : 'moved');
    // Typing decides its own caret, and it also relocates the whole paragraph.
    if (textChanged) {
      _forget();
      return;
    }
    var selection = widget.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _forget();
      return;
    }
    // Never after a hanging space — whatever placed the caret there.
    final stepped = _beforeHangingSpace(selection);
    if (stepped != null) {
      if (kCaretDebug) {
        debugPrint(
          '[caret] STEPPED back over the hanging space: '
          '${selection.baseOffset}/${selection.affinity.name} '
          '-> ${stepped.baseOffset}',
        );
      }
      _write(stepped);
      selection = stepped;
    }
    if (_dragging) {
      // A sideways drag may not change lines — Android's rule, and the one the
      // device trace showed Flutter breaking.
      if (_clampToDraggedLine(selection)) return;
      _rememberLine(selection);
      return;
    }
    if (_tapPoint != null) {
      // After the frame: the tap that moved the caret can arrive before the
      // editable has laid the text out, and the measurement needs a laid-out
      // paragraph.
      WidgetsBinding.instance.addPostFrameCallback((_) => _correct(selection));
      return;
    }
    // No pointer at all (IME cursor keys, a hardware keyboard): the platform's
    // caret is the right one, and second-guessing it is what would trap a
    // keyboard at the wrap boundary.
    _rememberLine(selection);
  }

  /// The line a caret at [selection] with [affinity] is drawn on, or null when
  /// the editable cannot answer.
  ({int line, RenderEditable editable})? _lineFor(
    TextSelection selection,
    TextAffinity affinity,
  ) {
    final editable = _findRenderEditable(context.findRenderObject());
    if (editable == null || !editable.attached || !editable.hasSize) {
      return null;
    }
    final lh = editable.preferredLineHeight;
    if (lh <= 0) return null;
    try {
      final rect = editable.getLocalRectForCaret(
        TextPosition(offset: selection.baseOffset, affinity: affinity),
      );
      return (line: (rect.top / lh).round(), editable: editable);
    } catch (_) {
      return null;
    }
  }

  void _rememberLine(TextSelection selection) {
    _lastCaretLine = _lineFor(selection, selection.affinity)?.line;
    _lastSelection = selection;
    _moveAtLastCaret = _move;
  }

  /// Writes [selection] back without re-entering this listener.
  void _write(TextSelection selection) {
    _correcting = true;
    widget.controller.selection = selection;
    _correcting = false;
  }

  /// The caret one step before a *hanging* space, or null when [selection] is
  /// not the caret after one.
  ///
  /// That caret — the soft-wrap boundary offset with `upstream` affinity,
  /// preceded by the space the line broke at — is drawn at the end of the line
  /// exactly where a caret after the last letter is drawn, and it is what a tap
  /// in the empty run after that letter produces. `EditText` never places it
  /// (`getOffsetForHorizontal` stops at the offset before the trailing
  /// whitespace on every line but the last), so neither does this. Only U+0020
  /// counts: a newline is a hard break whose following offset is legitimately
  /// the start of the next line, and nothing else hangs.
  TextSelection? _beforeHangingSpace(TextSelection selection) {
    if (selection.affinity != TextAffinity.upstream) return null;
    final offset = selection.baseOffset;
    final text = widget.controller.text;
    if (offset <= 0 || offset > text.length) return null;
    if (text.codeUnitAt(offset - 1) != 0x20) return null;
    // Only a soft wrap offers two lines for one offset; anywhere else the
    // caret after a space is an ordinary caret.
    final up = _lineFor(selection, TextAffinity.upstream);
    final down = _lineFor(selection, TextAffinity.downstream);
    if (up == null || down == null || up.line == down.line) return null;
    return TextSelection.collapsed(offset: offset - 1);
  }

  /// Refuses a **line change** that the finger did not ask for.
  ///
  /// This is the reported drag bug, caught on the device:
  ///
  /// ```
  /// sel=75 aff=downstream down=2@201   ← the start of line 2, correct
  /// sel=74 aff=downstream down=1@22    ← a line up, on a sideways nudge
  /// ```
  ///
  /// Offset 75 is the first character of line 2 and 74 is the last of line 1,
  /// so *as offsets* they are adjacent and the platform is not wrong. But in an
  /// RTL paragraph those two carets are at opposite corners — top-right of one
  /// line, bottom-left of the line above — so one pixel of horizontal drag
  /// throws the caret across the whole field. That is "I dragged towards the
  /// start of the line and it went to the end of the previous one".
  ///
  /// Android's `EditText` cannot do this: its handle drag resolves the **line
  /// from the finger's y** (`Layout.getLineForVertical`) and then clamps x
  /// *inside that line*, so sliding sideways parks the caret at the line's edge
  /// and stays there. Crossing lines is a vertical gesture. This restores that:
  /// while a finger is down, a caret that changes line without the finger
  /// having moved half a line vertically since the caret last moved is put
  /// back. It cannot trap the caret — lifting the finger clears the gesture,
  /// and any real vertical movement lets the change through.
  bool _clampToDraggedLine(TextSelection selection) {
    final previous = _lastCaretLine;
    final previousSelection = _lastSelection;
    // The finger's position at the last caret movement, or — for the first
    // movement of this drag — where it went down.
    final since = _moveAtLastCaret ?? _down;
    final now = _move;
    if (previous == null || previousSelection == null) return false;
    if (since == null || now == null) return false;

    final here = _lineFor(selection, selection.affinity);
    if (here == null || here.line == previous) return false;

    // The finger moved far enough vertically to mean it: let the line change.
    final travelled = (now.dy - since.dy).abs();
    if (travelled >= here.editable.preferredLineHeight / 2) return false;

    if (kCaretDebug) {
      debugPrint(
        '[caret] CLAMPED sideways drag tried line ${here.line} '
        '(was $previous, finger moved ${travelled.toStringAsFixed(1)}px)',
      );
    }
    _write(previousSelection);
    return true;
  }

  void _correct(TextSelection selection) {
    if (!mounted) return;
    // Nothing else moved the caret in the meantime.
    if (widget.controller.selection != selection) return;
    final tap = _tapPoint;
    if (tap == null) {
      _rememberLine(selection);
      return;
    }

    final editable = _findRenderEditable(context.findRenderObject());
    if (editable == null || !editable.attached || !editable.hasSize) return;

    final local = editable.globalToLocal(tap);
    final size = editable.size;
    // The tap was not on this field at all (it focused it from elsewhere, or it
    // belongs to some other widget entirely).
    if (local.dy < -_kTapSlop ||
        local.dy > size.height + _kTapSlop ||
        local.dx < -size.width ||
        local.dx > size.width * 2) {
      _rememberLine(selection);
      return;
    }
    final clamped = Offset(
      local.dx.clamp(0.5, size.width - 0.5),
      local.dy.clamp(0.5, size.height - 0.5),
    );

    bool onTapLine(TextPosition position) {
      final Rect rect;
      try {
        rect = editable.getLocalRectForCaret(position);
      } catch (_) {
        return false;
      }
      return clamped.dy >= rect.top - 1 && clamped.dy <= rect.bottom + 1;
    }

    final current = TextPosition(
      offset: selection.baseOffset,
      affinity: selection.affinity,
    );
    // The overwhelmingly common case: the caret is already where the finger
    // was, and this widget does nothing.
    if (onTapLine(current)) {
      if (kCaretDebug) debugPrint('[caret] ok — already on the tapped line');
      _rememberLine(selection);
      return;
    }
    if (kCaretDebug) {
      debugPrint(
        '[caret] MISMATCH caret is not on the tapped line '
        '(clamped=${clamped.dy.toStringAsFixed(0)})',
      );
    }

    // 1. The same offset, drawn on the other side of the soft wrap — stepped
    //    back over a hanging space if that is what the other side is.
    final flipped = _settled(
      TextSelection.collapsed(
        offset: selection.baseOffset,
        affinity: selection.affinity == TextAffinity.upstream
            ? TextAffinity.downstream
            : TextAffinity.upstream,
      ),
    );
    if (onTapLine(flipped.base)) {
      if (kCaretDebug) debugPrint('[caret] FIXED by flipping affinity');
      _apply(flipped);
      return;
    }

    // 2. The end of the tapped line, when that line ends in a newline. A tap
    //    in the empty run after the last word of a hard-broken line hits the
    //    newline, and the platform answers with the offset *after* it — the
    //    start of the next line, whatever the affinity. That is the caret
    //    behind «حرف آخر رو پاک کنی، میره اول خط بعدی» on a message typed with
    //    Enter: backspace removes the line break instead of the letter. The
    //    line the finger was on ends one offset earlier.
    final offset = selection.baseOffset;
    final text = widget.controller.text;
    if (offset > 0 &&
        offset <= text.length &&
        text.codeUnitAt(offset - 1) == 0x0A) {
      final beforeBreak = TextSelection.collapsed(offset: offset - 1);
      if (onTapLine(beforeBreak.base)) {
        if (kCaretDebug) {
          debugPrint('[caret] FIXED by stepping back over the newline');
        }
        _apply(beforeBreak);
        return;
      }
    }

    // 3. The platform's own hit test, with the touch point pulled inside the
    //    text box — Android's "line from y, then x within that line".
    final TextPosition hit;
    try {
      hit = editable.getPositionForPoint(editable.localToGlobal(clamped));
    } catch (_) {
      _rememberLine(selection);
      return;
    }
    final candidate = _settled(
      TextSelection.collapsed(offset: hit.offset, affinity: hit.affinity),
    );
    if (candidate != selection && onTapLine(candidate.base)) {
      if (kCaretDebug) debugPrint('[caret] FIXED by re-hit-test');
      _apply(candidate);
      return;
    }
    if (kCaretDebug) {
      debugPrint('[caret] GAVE UP — no candidate lands on the tapped line');
    }
    _rememberLine(selection);
  }

  /// [selection] with the hanging-space rule applied.
  TextSelection _settled(TextSelection selection) =>
      _beforeHangingSpace(selection) ?? selection;

  void _apply(TextSelection selection) {
    _write(selection);
    _rememberLine(selection);
  }

  /// Prints one line per caret movement, tagged `[caret]`, so a report of
  /// "the cursor jumps" can be read off `adb logcat` instead of guessed at.
  ///
  /// Left in behind [kCaretDebug] rather than deleted: this is the third time
  /// this behaviour has had to be diagnosed on a device, and the measurements
  /// it prints — which line the caret is drawn on versus which line the finger
  /// was on, and what character sits before the caret — are exactly the ones
  /// that are impossible to see from a video. It never prints the text.
  void _trace(String why) {
    try {
      final selection = widget.controller.selection;
      final text = widget.controller.text;
      final editable = _findRenderEditable(context.findRenderObject());
      final buffer = StringBuffer('[caret] $why');
      buffer.write(
        ' sel=${selection.baseOffset}..${selection.extentOffset}'
        ' aff=${selection.affinity.name}'
        ' len=${text.length}',
      );
      final o = selection.baseOffset;
      if (selection.isValid && o > 0 && o <= text.length) {
        buffer.write(
          ' prev=U+${text.codeUnitAt(o - 1).toRadixString(16).padLeft(4, '0')}',
        );
      }
      if (editable != null && editable.attached && editable.hasSize) {
        final lh = editable.preferredLineHeight;
        String lineOf(TextAffinity a) {
          try {
            final r = editable.getLocalRectForCaret(
              TextPosition(offset: selection.baseOffset, affinity: a),
            );
            return '${(r.top / lh).round()}@${r.left.toStringAsFixed(0)}';
          } catch (_) {
            return '?';
          }
        }

        buffer.write(' down=${lineOf(TextAffinity.downstream)}');
        buffer.write(' up=${lineOf(TextAffinity.upstream)}');
        buffer.write(' lines=${(editable.size.height / lh).round()}');
        buffer.write(' w=${editable.size.width.toStringAsFixed(0)}');
        final down = _down;
        if (down != null) {
          final local = editable.globalToLocal(down);
          buffer.write(
            ' finger=(${local.dx.toStringAsFixed(0)},'
            '${local.dy.toStringAsFixed(0)})'
            ' fingerLine=${(local.dy / lh).floor()}',
          );
        }
        buffer.write(' tap=${_tapPoint != null} drag=$_dragging');
      }
      debugPrint(buffer.toString());
    } catch (e) {
      debugPrint('[caret] trace failed: $e');
    }
  }

  static RenderEditable? _findRenderEditable(RenderObject? node) {
    if (node == null) return null;
    if (node is RenderEditable) return node;
    RenderEditable? found;
    node.visitChildren((child) {
      found ??= _findRenderEditable(child);
    });
    return found;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
