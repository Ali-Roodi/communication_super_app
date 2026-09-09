import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/message_text_scale.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';

/// Scales the text of everything under it, and lets a two-finger pinch change
/// that scale.
///
/// A conversation is nothing but text, read by people of every eyesight, and
/// the phone-wide font size is a poor answer — turning it up to read one SMS
/// turns the whole system up. The pinch is where anybody looks for this, and
/// it writes the same persisted value the «اندازه متن پیام» row in Settings
/// does, so the gesture and the setting are one thing.
///
/// The scale multiplies the platform's own scaling rather than replacing it
/// (see [MessageTextScaler]) — a user who already raised Android's font size
/// must not have it silently reset by opening a chat.
///
/// ## Why this is a raw [Listener] and not a `ScaleGestureRecognizer`
///
/// It was a recognizer, and the recognizer could only ever win the gesture
/// arena when **both fingers landed in the same few milliseconds** — which is
/// exactly how it was reported: «حتما باید انگشت‌ها همزمان روی صفحه باشه».
///
/// The reason is structural, not a tuning problem. The list's own
/// `VerticalDragGestureRecognizer` sits *below* this widget in the hit-test
/// path, so it is the first member of every pointer's arena; the moment one
/// finger moves past touch slop it accepts and every other member is rejected.
/// Rejection runs through `OneSequenceGestureRecognizer.rejectGesture`, which
/// calls `stopTrackingPointer` — so by the time a second finger arrives the
/// scale recognizer is no longer tracking the first one and can never see two.
/// And it cannot win the *second* pointer's arena either: an accepted drag
/// recognizer rejoins each new pointer's arena already accepted, while a scale
/// recognizer needs movement before it may claim anything, so the sweep hands
/// that arena to the drag as well. Nothing that lives in the arena can recover
/// from this; the old `_PinchOnlyScaleRecognizer`, which swallowed its own
/// *acceptance* for one finger, addressed a different half of the problem (not
/// stealing the scroll) and never this one.
///
/// A [Listener] is outside the arena entirely: it is handed every pointer that
/// hit-tests to it whatever any recognizer decides, so the second finger starts
/// a pinch whenever it arrives — mid-scroll, a second later, either order. The
/// scroll is then stopped by swapping the list's physics for
/// [NeverScrollableScrollPhysics] through [PinchScope] for as long as two
/// fingers are down (`Scrollable.setCanDrag(false)` cancels the live drag and
/// the position is carried over, so nothing jumps).
class PinchTextScale extends StatefulWidget {
  final Widget child;

  /// Current persisted scale (1.0 = normal).
  final double scale;

  /// Called once, on release, with the settled scale. Not called on every
  /// frame of the pinch: this writes to SharedPreferences and rebuilds a bloc.
  final ValueChanged<double> onScaleChanged;

  const PinchTextScale({
    super.key,
    required this.child,
    required this.scale,
    required this.onScaleChanged,
  });

  @override
  State<PinchTextScale> createState() => _PinchTextScaleState();
}

class _PinchTextScaleState extends State<PinchTextScale> {
  /// The scale being drawn right now. Equals `widget.scale` except during a
  /// pinch, when it follows the fingers.
  double? _live;

  /// Scale at the moment the pinch started, the factor is applied to this.
  double _startScale = MessageTextScale.normal;

  /// Every finger currently on this subtree, by pointer id. Two of them is a
  /// pinch; the map is what lets the second one arrive at any time.
  final Map<int, Offset> _pointers = <int, Offset>{};

  /// Distance between the two fingers when the pinch began.
  double _baseSpan = 0;

  /// Whether a pinch owns the screen right now. A [ValueNotifier] rather than
  /// `setState` because its one consumer is the list's `physics`, reached
  /// through [PinchScope] — see the class doc.
  final ValueNotifier<bool> _pinching = ValueNotifier<bool>(false);

  /// How much of a spread the gesture asks for.
  ///
  /// The raw finger ratio (a gain of 1.0) is what the recognizer used, and it
  /// made even a successful pinch feel stiff: reaching the next step from
  /// «۱۰۰٪» meant spreading the fingers a full 15 %, and the far ends of the
  /// range needed most of the screen. At 1.6 one step is about a 9 % spread and
  /// «۲۰۰٪» is reachable in one comfortable gesture, while the movement still
  /// tracks the fingers closely enough to aim with.
  static const double _gain = 1.6;

  /// Below this the fingers are effectively together and the ratio is noise.
  static const double _minSpan = 24.0;

  double get _effective => _live ?? widget.scale;

  @override
  void dispose() {
    _pinching.dispose();
    super.dispose();
  }

  static double _spanOf(Iterable<Offset> points) {
    final list = points.toList(growable: false);
    return (list[0] - list[1]).distance;
  }

  void _onPointerDown(PointerDownEvent event) {
    // A third finger is ignored rather than tracked: the pinch keeps following
    // the two it started with, which is what every zoomable surface does.
    if (_pointers.length >= 2) return;
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) _beginPinch();
  }

  void _beginPinch() {
    final span = _spanOf(_pointers.values);
    if (span < _minSpan) {
      // Two fingers touching: wait for them to separate before taking a
      // baseline, or the first movement divides by ~nothing.
      _baseSpan = 0;
      return;
    }
    _baseSpan = span;
    _startScale = widget.scale;
    _pinching.value = true;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    if (_pointers.length < 2) return;
    if (_baseSpan == 0) {
      _beginPinch();
      return;
    }
    final span = _spanOf(_pointers.values);
    if (span <= 0) return;
    final next = MessageTextScale.clamp(
      _startScale * math.pow(span / _baseSpan, _gain).toDouble(),
    );
    if (next == _live) return;
    setState(() => _live = next);
  }

  void _onPointerUp(PointerEvent event) {
    if (_pointers.remove(event.pointer) == null) return;
    if (_pointers.length >= 2) return;
    _endPinch();
  }

  void _endPinch() {
    _baseSpan = 0;
    // The list can scroll again. The finger still on screen does not carry the
    // pinch's movement into a fling: the drag recognizer was cancelled when the
    // physics changed and only starts over from where that finger is now.
    if (_pinching.value) _pinching.value = false;
    final live = _live;
    if (live == null) return;
    // Settled onto one of the offered sizes, so the gesture and the settings
    // row always name the same thing.
    final settled = MessageTextScale.snap(live);
    setState(() => _live = null);
    if (settled != widget.scale) widget.onScaleChanged(settled);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scale = _effective;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      // The list still owns every pointer it would have owned — a Listener
      // takes part in no arena and steals nothing.
      behavior: HitTestBehavior.deferToChild,
      child: PinchScope(
        notifier: _pinching,
        child: Stack(
          children: [
            MediaQuery(
              data: media.copyWith(
                textScaler: scale == MessageTextScale.normal
                    ? media.textScaler
                    : MessageTextScaler(base: media.textScaler, factor: scale),
              ),
              child: widget.child,
            ),
            // Says what the pinch is doing while it happens, and disappears with
            // it. Without it the only feedback is the text itself, which is hard
            // to judge against a size you can no longer see.
            if (_live != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.inverseSurface.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          MessageTextScale.label(_live!),
                          // Deliberately outside the scaled subtree: a readout of
                          // the text size must not itself change size with it.
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onInverseSurface,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Whether a two-finger pinch is happening in the conversation right now.
///
/// The one consumer is the thread list's `physics`: while this is true it is
/// [NeverScrollableScrollPhysics], so the second finger of a pinch does not
/// also drag the list. It has to be an inherited value rather than a callback
/// because the list is built deep inside [PinchTextScale]'s child, and an
/// [InheritedNotifier] so that starting and ending a pinch rebuilds only the
/// widgets that asked.
class PinchScope extends InheritedNotifier<ValueNotifier<bool>> {
  const PinchScope({
    super.key,
    required ValueNotifier<bool> notifier,
    required super.child,
  }) : super(notifier: notifier);

  static bool isPinching(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PinchScope>()
          ?.notifier
          ?.value ??
      false;
}

/// «اندازه متن» from the conversation's overflow menu.
///
/// The same persisted value the pinch and the Settings row use. It exists
/// because a two-finger gesture is not discoverable, and the person who needs
/// bigger text is the least likely to go hunting for one.
Future<void> showMessageTextSizeSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => BlocProvider.value(
      value: context.read<SettingsBloc>(),
      child: const _TextSizeSheet(),
    ),
  );
}

class _TextSizeSheet extends StatelessWidget {
  const _TextSizeSheet();

  @override
  Widget build(BuildContext context) {
    final steps = MessageTextScale.steps;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: BlocBuilder<SettingsBloc, SettingsState>(
          buildWhen: (a, b) => a.messageTextScale != b.messageTextScale,
          builder: (context, state) {
            final scale = state.messageTextScale;
            final index = steps.indexOf(MessageTextScale.snap(scale));
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'اندازه متن پیام',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Text(MessageTextScale.label(scale)),
                    ],
                  ),
                  Slider(
                    value: (index < 0 ? steps.indexOf(1.0) : index).toDouble(),
                    min: 0,
                    max: (steps.length - 1).toDouble(),
                    divisions: steps.length - 1,
                    label: MessageTextScale.label(scale),
                    onChanged: (v) => context.read<SettingsBloc>().add(
                      SetMessageTextScale(steps[v.round()]),
                    ),
                  ),
                  // Judged by reading it, not by the number above it.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      'نمونه متن پیام',
                      textScaler: TextScaler.linear(scale),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
