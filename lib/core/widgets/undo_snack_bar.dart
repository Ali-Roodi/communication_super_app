import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/persian_utils.dart';

/// The app's transient confirmation bar: a short message, an optional undo, and
/// a **visible countdown** that ends by taking the bar away.
///
/// Two reasons this exists instead of a bare `SnackBar`:
///
/// 1. **A `SnackBar` carrying an action is not guaranteed to time out.**
///    `ScaffoldMessengerState` skips starting its dismissal timer while
///    `MediaQuery.accessibleNavigation` is true and the bar has an action — the
///    assumption being that a screen-reader user needs unlimited time to reach
///    it. With any accessibility service active, «گفتگو بایگانی شد» therefore
///    sat on the inbox until something else replaced it. This helper owns its
///    own [Timer] and hides the bar itself, so the countdown is authoritative
///    no matter what the platform reports.
/// 2. The countdown is *shown*. An undo the user cannot see expiring is a
///    guessing game; the ring around «واگرد» says how long is left.
///
/// Always replaces whatever is on screen ([ScaffoldMessengerState.clearSnackBars])
/// — two stacked confirmations for the same gesture is never what was meant.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showUndoSnack(
  BuildContext context, {
  required String message,
  VoidCallback? onUndo,
  String undoLabel = 'واگرد',
  Duration duration = kUndoSnackDuration,
  /// The shrinking ring is right for an *undo* — a window that closes on
  /// something already done. Turn it off for an action that merely offers a
  /// shortcut («تنظیمات»), where a ticking clock implies a deadline that isn't
  /// one.
  bool showCountdown = true,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();

  late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller;
  var closed = false;

  controller = messenger.showSnackBar(
    SnackBar(
      duration: duration,
      // The action lives inside `content` rather than in `action:` so the
      // countdown ring can sit next to its label; `SnackBarAction` takes a
      // string only.
      content: _UndoSnackContent(
        message: message,
        undoLabel: undoLabel,
        duration: duration,
        showCountdown: showCountdown,
        onUndo: onUndo == null
            ? null
            : () {
                onUndo();
                if (!closed) {
                  messenger.hideCurrentSnackBar(
                    reason: SnackBarClosedReason.action,
                  );
                }
              },
      ),
    ),
  );

  controller.closed.then((_) => closed = true);
  // The backstop: fires whether or not the framework started its own timer.
  // A bar that was already dismissed (or replaced by a newer one) has completed
  // `closed`, so this cannot reach past its own snack bar.
  Timer(duration + const Duration(milliseconds: 100), () {
    if (!closed) {
      messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
    }
  });

  return controller;
}

/// How long a confirmation stays up. Three seconds is what «گفتگو بایگانی شد»
/// was asked for and it reads comfortably at Persian text length; anything
/// shorter makes «واگرد» unreachable.
const Duration kUndoSnackDuration = Duration(seconds: 3);

class _UndoSnackContent extends StatelessWidget {
  const _UndoSnackContent({
    required this.message,
    required this.undoLabel,
    required this.duration,
    required this.onUndo,
    required this.showCountdown,
  });

  final String message;
  final String undoLabel;
  final Duration duration;
  final VoidCallback? onUndo;
  final bool showCountdown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Row(
        children: [
          Expanded(child: Text(message)),
          if (onUndo != null) ...[
            const SizedBox(width: 8),
            if (showCountdown)
              _CountdownRing(duration: duration, color: scheme.inversePrimary),
            TextButton(
              onPressed: onUndo,
              style: TextButton.styleFrom(
                foregroundColor: scheme.inversePrimary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(undoLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// A shrinking ring with the whole seconds left in its middle.
class _CountdownRing extends StatefulWidget {
  const _CountdownRing({required this.duration, required this.color});

  final Duration duration;
  final Color color;

  @override
  State<_CountdownRing> createState() => _CountdownRingState();
}

class _CountdownRingState extends State<_CountdownRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    return SizedBox(
      width: 22,
      height: 22,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final remaining = 1 - _controller.value;
          // Ceil so the ring reads «۳» the instant it appears and only reaches
          // «۱» in the last second — a floor would open on «۲».
          final seconds = (remaining * total / 1000).ceil().clamp(1, 99);
          return Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: remaining,
                strokeWidth: 2,
                color: widget.color,
                backgroundColor: widget.color.withValues(alpha: 0.24),
              ),
              Text(
                PersianUtils.toPersianNumber('$seconds'),
                style: TextStyle(
                  fontSize: 10,
                  height: 1,
                  color: widget.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
