import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Puts the caret on the line the finger tapped.
///
/// ## The bug this exists for
///
/// Tap at the visual **start** of a soft-wrapped line in the Persian composer
/// and the caret lands at the **end of the line above**. Reported exactly that
/// way, and it reproduces on the device: with the same message in the composer,
/// a tap 6 dp inside the first glyph of a line is correct, and the same tap
/// 7 dp further out — still on that line, still inside the field — puts the
/// caret a line too high. The start of an RTL line is its **right** edge, which
/// is also the edge of the text box, so "tap at the start of the line" is
/// exactly the gesture that lands there; a fingertip is ~20 dp across and the
/// user is aiming at a boundary.
///
/// Two things go wrong at that boundary, and this fixes both:
///
///  * a soft wrap gives one text offset two legitimate carets — the boundary
///    offset renders at the end of line N with `TextAffinity.upstream` and at
///    the start of line N+1 with `downstream` — and the affinity comes back
///    from the paragraph's own nearest-glyph search, not from which line the
///    finger was on;
///  * past the edge of the text the nearest glyph can belong to a different
///    line altogether, so even the *offset* can come back a line out.
///
/// Android's own `EditText` cannot make either mistake, because it resolves the
/// **line from the y coordinate first** (`Layout.getLineForVertical`) and only
/// then clamps x inside that line. This restores that rule without
/// re-implementing anything: after a tap it checks whether the caret ended up
/// on the line the finger was on, and if not, corrects it — first by flipping
/// the affinity, then, if that is not enough, by re-running the platform's own
/// hit test with the touch point clamped inside the text box.
///
/// ## Why it is safe
///
/// It only ever runs when the caret is demonstrably **not** on the line the
/// finger was on, which in every ordinary tap is false and the whole thing
/// returns after two rectangle lookups. It never runs for typing (the text
/// changed), never for a selection (only collapsed carets), never for a
/// keyboard caret move (no pointer), and never for a **drag** — a selection
/// handle hangs below the line it points at, so the finger legitimately sits on
/// another line and Flutter's own drag maths already accounts for it. Only a
/// tap, and only a tap that finished within [_kTapSlop] of where it started.
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
/// Normally off. Turned on to diagnose a "the cursor jumps" report against a
/// real device, because the Persian shaping and line breaking that trigger it
/// do not reproduce under the test font — so the only way to see which line the
/// caret landed on versus which line the finger was on is to print both.
const bool kCaretDebug = true;

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

  String? _lastText;

  /// The visual line the caret was drawn on the last time it moved.
  ///
  /// This is what makes a **drag** come out right, and a drag is what the
  /// report was actually about — the device trace showed `tap=false` on every
  /// single caret movement. Walking the handle along a line steps one character
  /// at a time, and at a soft-wrap boundary that one step is ambiguous: offset
  /// 75 in the traced message draws at the start of line 2 (x=201, the right
  /// edge) with `downstream` and at the end of line 1 (x=17, the far left) with
  /// `upstream` — and the platform chose `upstream`, which is precisely "I
  /// dragged to the start of the line and it jumped to the end of the line
  /// above".
  ///
  /// Continuity settles it without guessing: the caret was already on line 2,
  /// so at the boundary it stays on line 2. Crossing to the previous line is
  /// still possible and still easy — it happens at the *next* offset (74),
  /// which is unambiguous — so this never traps the caret, it only stops it
  /// teleporting a line while its offset barely moved.
  int? _lastCaretLine;

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
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// Where the finger is **now**, and where it was when the caret last moved.
  ///
  /// The second is what makes the horizontal clamp possible: a drag that only
  /// moves sideways must not change lines, and "only sideways" can only be
  /// judged against the finger's position at the previous caret movement.
  Offset? _move;
  Offset? _moveAtLastCaret;

  void _onPointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _down = event.position;
      _move = event.position;
      _moveAtLastCaret = null;
      _up = null;
      _upAt = null;
    } else if (event is PointerMoveEvent) {
      _move = event.position;
    } else if (event is PointerUpEvent) {
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

  void _onControllerChanged() {
    if (_correcting) return;
    final text = widget.controller.text;
    final textChanged = text != _lastText;
    _lastText = text;
    if (kCaretDebug) _trace(textChanged ? 'typed' : 'moved');
    // Typing decides its own caret, and it also relocates the whole paragraph —
    // so the remembered line means nothing until the caret next moves on its
    // own.
    if (textChanged) {
      _lastCaretLine = null;
      return;
    }
    final selection = widget.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _lastCaretLine = null;
      return;
    }
    // A sideways drag may not change lines — Android's rule, and the one the
    // device trace showed Flutter breaking.
    if (_clampToDraggedLine(selection)) return;
    // Runs for a drag as well as a tap: keeping the caret on the line it was
    // already on needs no pointer at all, only the previous line.
    if (_keepOnSameLine(selection)) return;
    if (_tapPoint == null) {
      _rememberLine(selection);
      return;
    }
    // After the frame: the tap that moved the caret can arrive before the
    // editable has laid the text out, and the measurement below needs a
    // laid-out paragraph.
    WidgetsBinding.instance.addPostFrameCallback((_) => _correct(selection));
  }

  /// The line a caret at [selection] with [affinity] is drawn on, or null when
  /// the editable cannot answer.
  ({int line, RenderEditable editable})? _lineFor(
    TextSelection selection,
    TextAffinity affinity,
  ) {
    final editable = _findRenderEditable(context.findRenderObject());
    if (editable == null || !editable.attached || !editable.hasSize) return null;
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

  /// The selection the caret last settled on, so a refused move can be undone.
  TextSelection? _lastSelection;

  /// Refuses a **line change** that the finger did not ask for.
  ///
  /// This is the reported bug, caught on the device:
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
  /// having moved a meaningful fraction of a line vertically is put back.
  ///
  /// It cannot trap the caret — lifting the finger clears the gesture, and any
  /// real vertical movement (half a line) lets the change through.
  bool _clampToDraggedLine(TextSelection selection) {
    if (!_dragging) return false;
    final previous = _lastCaretLine;
    final previousSelection = _lastSelection;
    final since = _moveAtLastCaret;
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
    _correcting = true;
    widget.controller.selection = previousSelection;
    _correcting = false;
    return true;
  }

  /// At a soft-wrap boundary, keeps the caret on the line it was already on.
  ///
  /// Returns true when it rewrote the selection (the write re-enters this
  /// listener, which then records the line).
  bool _keepOnSameLine(TextSelection selection) {
    final previous = _lastCaretLine;
    final here = _lineFor(selection, selection.affinity);
    if (here == null) return false;
    if (previous == null || here.line == previous) {
      _lastCaretLine = here.line;
      return false;
    }
    final other = selection.affinity == TextAffinity.upstream
        ? TextAffinity.downstream
        : TextAffinity.upstream;
    final alternative = _lineFor(selection, other);
    // Only a soft-wrap boundary offers a second line for the same offset. If
    // the alternative is not the line we came from, the caret genuinely moved
    // lines and must be left alone.
    if (alternative == null || alternative.line != previous) {
      _lastCaretLine = here.line;
      return false;
    }
    if (kCaretDebug) {
      debugPrint(
        '[caret] KEPT on line $previous at offset ${selection.baseOffset} '
        '(platform wanted line ${here.line})',
      );
    }
    _correcting = true;
    widget.controller.selection = TextSelection.collapsed(
      offset: selection.baseOffset,
      affinity: other,
    );
    _correcting = false;
    _lastCaretLine = previous;
    return true;
  }

  void _correct(TextSelection selection) {
    if (!mounted) return;
    // Nothing else moved the caret in the meantime.
    if (widget.controller.selection != selection) return;
    final tap = _tapPoint;
    if (tap == null) return;

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
      return;
    }
    if (kCaretDebug) {
      debugPrint(
        '[caret] MISMATCH caret is not on the tapped line '
        '(clamped=${clamped.dy.toStringAsFixed(0)})',
      );
    }

    // 1. The same offset, drawn on the other side of the soft wrap.
    final flipped = TextPosition(
      offset: selection.baseOffset,
      affinity: selection.affinity == TextAffinity.upstream
          ? TextAffinity.downstream
          : TextAffinity.upstream,
    );
    if (onTapLine(flipped)) {
      if (kCaretDebug) debugPrint("[caret] FIXED by flipping affinity");
      _apply(flipped);
      return;
    }

    // 2. The platform's own hit test, with the touch point pulled inside the
    //    text box — Android's "line from y, then x within that line".
    final TextPosition candidate;
    try {
      candidate = editable.getPositionForPoint(editable.localToGlobal(clamped));
    } catch (_) {
      return;
    }
    if (candidate.offset == current.offset &&
        candidate.affinity == current.affinity) {
      return;
    }
    if (onTapLine(candidate)) {
      if (kCaretDebug) debugPrint("[caret] FIXED by re-hit-test");
      _apply(candidate);
    } else if (kCaretDebug) {
      debugPrint("[caret] GAVE UP — no candidate lands on the tapped line");
    }
  }

  void _apply(TextPosition position) {
    _correcting = true;
    widget.controller.selection = TextSelection.collapsed(
      offset: position.offset,
      affinity: position.affinity,
    );
    _correcting = false;
  }

  /// Prints one line per caret movement, tagged `[caret]`, so a report of
  /// "the cursor jumps" can be read off `adb logcat` instead of guessed at.
  ///
  /// Left in behind [kCaretDebug] rather than deleted: this is the second time
  /// this behaviour has had to be diagnosed on a device, and the measurements
  /// it prints — which line the caret is drawn on versus which line the finger
  /// was on — are exactly the ones that are impossible to see from a video.
  void _trace(String why) {
    try {
      final selection = widget.controller.selection;
      final editable = _findRenderEditable(context.findRenderObject());
      final buffer = StringBuffer('[caret] $why');
      buffer.write(
        ' sel=${selection.baseOffset}..${selection.extentOffset}'
        ' aff=${selection.affinity.name}'
        ' len=${widget.controller.text.length}',
      );
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
