import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import '../../models/message_model.dart';
import 'message_bubble.dart';

/// One row of the long-press action menu.
class MessageAction {
  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  /// Destructive rows (حذف) are tinted red, as in Google Messages.
  final bool danger;

  const MessageAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.danger = false,
  });
}

/// Long-press presentation for a chat bubble: the background blurs away, the
/// bubble the finger was on lifts out of the list, and the action menu opens
/// next to it.
///
/// The lifted copy is **freely selectable text** — that is the point of the
/// mode. There is deliberately no «انتخاب متن» menu row any more (and no
/// select-text dialog): the user drags the handles right on the lifted bubble
/// and copies from the selection toolbar, the way Telegram does it.
///
/// [anchor] is the bubble box's rect in global coordinates — [MessageBubble]
/// measures it and hands it over with the long-press.
///
/// The lifted copy is a [MessageBubbleBody] like the flat one, so a template
/// message shows (and copies out of) its rebuilt text rather than the stored
/// wire payload — no decoding happens here. The menu rows are supplied by the
/// caller, which is where کپی / هدایت resolve the display text.
Future<void> showMessageActionOverlay(
  BuildContext context, {
  required MessageModel message,
  required Rect anchor,
  required bool isLastInGroup,
  required bool showLinkPreview,
  required List<MessageAction> actions,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    _MessageActionRoute(
      message: message,
      anchor: anchor,
      isLastInGroup: isLastInGroup,
      showLinkPreview: showLinkPreview,
      actions: actions,
    ),
  );
}

// The lifted bubble used to be drawn 6 % larger, through a `Transform.scale`
// around the whole copy — and that scale is why selecting text on it was
// imprecise. `SelectableRegion` positions the **magnifier** from
// `getTransformTo(null).getTranslation()`, i.e. the translation only: under any
// scale the focal point drifts by `(scale − 1) × offset-inside-the-bubble`, so
// on a long message the glass showed a different line than the one the handle
// was on — and the magnifier is the whole precision aid. The same mismatch runs
// through the handle drag, which subtracts a *local* half-line-height from a
// *global* drag position. The lift is carried by the movement, the shadow and
// the blurred backdrop instead; nothing scales, so every coordinate the
// selection machinery computes is exact.

const double _kMenuWidth = 240;
const double _kMenuRowHeight = 48;
const double _kGap = 12;

class _MessageActionRoute extends PopupRoute<void> {
  _MessageActionRoute({
    required this.message,
    required this.anchor,
    required this.isLastInGroup,
    required this.showLinkPreview,
    required this.actions,
  });

  final MessageModel message;
  final Rect anchor;
  final bool isLastInGroup;
  final bool showLinkPreview;
  final List<MessageAction> actions;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'بستن';

  // The scrim is painted inside the page (it has to be blurred), so the
  // route's own barrier stays invisible — it is only there to catch the
  // dismissing tap.
  @override
  Color? get barrierColor => null;

  @override
  bool get opaque => false;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _MessageActionLayer(
      animation: animation,
      message: message,
      anchor: anchor,
      isLastInGroup: isLastInGroup,
      showLinkPreview: showLinkPreview,
      actions: actions,
    );
  }
}

class _MessageActionLayer extends StatelessWidget {
  const _MessageActionLayer({
    required this.animation,
    required this.message,
    required this.anchor,
    required this.isLastInGroup,
    required this.showLinkPreview,
    required this.actions,
  });

  final Animation<double> animation;
  final MessageModel message;
  final Rect anchor;
  final bool isLastInGroup;
  final bool showLinkPreview;
  final List<MessageAction> actions;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final isSent = message.type == MessageType.sent;

    final safeTop = media.padding.top + 8;
    // The composer's keyboard may still be up when the long-press lands, and
    // the menu must not end up behind it.
    final safeBottom =
        math.max(media.padding.bottom, media.viewInsets.bottom) + 8;
    final menuHeight = actions.length * _kMenuRowHeight + 16;

    // The bubble is capped so the menu always has room under it; anything
    // longer scrolls inside the lifted copy.
    final maxBubbleHeight = math.max(
      120.0,
      size.height - safeTop - safeBottom - menuHeight - _kGap * 2,
    );
    final bubbleHeight = math.min(anchor.height, maxBubbleHeight);
    final overflows = anchor.height > maxBubbleHeight;

    var top = anchor.top;
    if (top + bubbleHeight + _kGap + menuHeight > size.height - safeBottom) {
      top = size.height - safeBottom - menuHeight - _kGap - bubbleHeight;
    }
    top = math.max(top, safeTop);

    final menuTop = top + bubbleHeight + _kGap;
    // Menus in Google Messages hang from the bubble's own edge — and a sent
    // bubble hugs the RIGHT of the thread (see MessageBubble: the sides are
    // physical, not directional).
    final rawMenuLeft = isSent ? anchor.right - _kMenuWidth : anchor.left;
    final menuLeft = rawMenuLeft.clamp(8.0, size.width - _kMenuWidth - 8);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Stack(
        children: [
          // Scrim + blur. Ignores pointers so the dismissing tap reaches the
          // route's modal barrier underneath.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: animation,
                builder: (context, _) {
                  final t = Curves.easeOut.transform(animation.value);
                  return BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 14 * t, sigmaY: 14 * t),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.42 * t),
                    ),
                  );
                },
              ),
            ),
          ),
          _LiftedBubble(
            animation: animation,
            message: message,
            anchor: anchor,
            isLastInGroup: isLastInGroup,
            showLinkPreview: showLinkPreview,
            top: top,
            height: bubbleHeight,
            scrollable: overflows,
          ),
          Positioned(
            top: menuTop,
            left: menuLeft,
            width: _kMenuWidth,
            child: _ActionMenu(animation: animation, actions: actions),
          ),
        ],
      ),
    );
  }
}

/// The bubble copy: slides from where it sat in the list to its lifted
/// position and hands its text over to the selection machinery. It is drawn at
/// its own size — see the note on the removed zoom above.
class _LiftedBubble extends StatelessWidget {
  const _LiftedBubble({
    required this.animation,
    required this.message,
    required this.anchor,
    required this.isLastInGroup,
    required this.showLinkPreview,
    required this.top,
    required this.height,
    required this.scrollable,
  });

  final Animation<double> animation;
  final MessageModel message;
  final Rect anchor;
  final bool isLastInGroup;
  final bool showLinkPreview;
  final double top;
  final double height;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    Widget bubble = MessageBubbleBody(
      message: message,
      isLastInGroup: isLastInGroup,
      showLinkPreview: showLinkPreview,
      enableLinkTaps: false,
      selectable: true,
      onCopied: () {
        // Both are resolved before the pop — the context is gone after it.
        final navigator = Navigator.of(context);
        final messenger = ScaffoldMessenger.of(context);
        navigator.maybePop();
        messenger.showSnackBar(const SnackBar(content: Text('کپی شد')));
      },
    );

    if (scrollable) {
      bubble = SizedBox(
        height: height,
        child: SingleChildScrollView(child: bubble),
      );
    }

    // Drop shadow only while lifted — the inline bubble is flat.
    bubble = Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: bubble,
      ),
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(animation.value);
        return Positioned(
          top: ui.lerpDouble(anchor.top, top, t)!,
          left: anchor.left,
          width: anchor.width,
          child: child!,
        );
      },
      child: bubble,
    );
  }
}

/// The action card. Rows pop the overlay first, then run — so the caller's
/// dialogs and sheets open onto a clean screen.
class _ActionMenu extends StatelessWidget {
  const _ActionMenu({required this.animation, required this.actions});

  final Animation<double> animation;
  final List<MessageAction> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.85, end: 1).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
        ),
        alignment: Alignment.topCenter,
        child: Material(
          color: cs.surfaceContainerHigh,
          elevation: 3,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              for (final action in actions)
                InkWell(
                  onTap: () {
                    Navigator.of(context).pop();
                    action.onSelected();
                  },
                  child: SizedBox(
                    height: _kMenuRowHeight,
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
                        Icon(
                          action.icon,
                          size: 20,
                          color: action.danger
                              ? AppColors.danger
                              : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            action.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: action.danger
                                  ? AppColors.danger
                                  : cs.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
