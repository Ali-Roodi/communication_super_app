import 'package:flutter/gestures.dart';
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

  double get _effective => _live ?? widget.scale;

  void _onStart(ScaleStartDetails details) {
    _startScale = widget.scale;
  }

  void _onUpdate(ScaleUpdateDetails details) {
    // One finger is the list's scroll, never a zoom. The recognizer below
    // already refuses to claim the arena for it; this is the second guard.
    if (details.pointerCount < 2) return;
    final next = MessageTextScale.clamp(_startScale * details.scale);
    if (next == _live) return;
    setState(() => _live = next);
  }

  void _onEnd(ScaleEndDetails details) {
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
    return RawGestureDetector(
      gestures: {
        _PinchOnlyScaleRecognizer:
            GestureRecognizerFactoryWithHandlers<_PinchOnlyScaleRecognizer>(
              () => _PinchOnlyScaleRecognizer(),
              (instance) => instance
                ..onStart = _onStart
                ..onUpdate = _onUpdate
                ..onEnd = _onEnd,
            ),
      },
      // The list still owns every pointer it would have owned; this recognizer
      // only ever joins in for a genuine two-finger pinch.
      behavior: HitTestBehavior.deferToChild,
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
                          color: Theme.of(context).colorScheme.onInverseSurface,
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
    );
  }
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

/// A [ScaleGestureRecognizer] that refuses to win the gesture arena with a
/// single finger.
///
/// This is the load-bearing part. `ScaleGestureRecognizer` treats a one-finger
/// drag as a pan and claims the arena for it, which would take the conversation
/// list's scroll away — the primary interaction on the screen — in exchange for
/// a gesture nobody made. Swallowing the acceptance (rather than *rejecting*)
/// keeps the recognizer alive, so a second finger arriving a moment later still
/// starts a real pinch.
class _PinchOnlyScaleRecognizer extends ScaleGestureRecognizer {
  @override
  // ignore: must_call_super
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted && pointerCount < 2) return;
    super.resolve(disposition);
  }
}
