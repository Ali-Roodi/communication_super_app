import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import '../../models/message_model.dart';
import '../../models/template_wire.dart';
import 'link_preview_card.dart';
import 'linkified_text.dart';

/// The width a bubble may occupy, as a fraction of the screen. Shared with the
/// long-press overlay so the zoomed copy wraps its text identically.
const double kBubbleMaxWidthFactor = 0.75;

/// The decorated bubble box on its own — colour, corner radii and body text —
/// without the surrounding row, timestamp or gestures.
///
/// Rendered twice: inline in the conversation list, and again (with
/// [selectable] on) as the lifted copy inside the long-press overlay. Keeping
/// one widget for both is what makes the zoom read as the *same* bubble.
class MessageBubbleBody extends StatelessWidget {
  final MessageModel message;
  final bool isLastInGroup;
  final bool showLinkPreview;

  /// Links render styled but inert while the chat is in multi-select mode (the
  /// tap belongs to the selection) and inside the overlay (the tap belongs to
  /// text selection).
  final bool enableLinkTaps;

  /// Renders the body as freely selectable text with drag handles — the
  /// overlay's whole point.
  final bool selectable;

  /// Measured by the list so the overlay knows where to lift from.
  final Key? boxKey;

  /// Invoked after the selection toolbar's «کپی», so the overlay can dismiss.
  final VoidCallback? onCopied;

  /// Inner padding of the bubble. Public because the overlay converts the
  /// press position from box coordinates into text coordinates with it.
  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 10,
  );

  const MessageBubbleBody({
    super.key,
    required this.message,
    required this.isLastInGroup,
    this.showLinkPreview = true,
    this.enableLinkTaps = true,
    this.selectable = false,
    this.boxKey,
    this.onCopied,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSent = message.type == MessageType.sent;

    // Google Messages never fills a bubble with the saturated primary: sent
    // messages use the tonal primary container, received ones a neutral
    // container. Both keep body text at full contrast.
    final bubbleColor = isSent ? cs.bubbleOutgoing : cs.bubbleIncoming;
    final textColor = isSent ? cs.onBubbleOutgoing : cs.onSurface;

    const r = Radius.circular(20);
    const tail = Radius.circular(4);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: isSent ? r : (isLastInGroup ? tail : r),
      bottomRight: isSent ? (isLastInGroup ? tail : r) : r,
    );

    // A built-in template travels as a compact payload (see [TemplateWire]); the
    // stored row keeps it verbatim — that is what the SMS provider holds and
    // what the mirror-sync diffs against — so it is rebuilt here, at render
    // time, and every use of the body below goes through the rebuilt text.
    final body = TemplateWire.displayText(message.body);

    final previewUrl = showLinkPreview ? LinkifiedText.firstUrl(body) : null;

    return Container(
      key: boxKey,
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * kBubbleMaxWidthFactor,
      ),
      padding: padding,
      decoration: BoxDecoration(color: bubbleColor, borderRadius: radius),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableBubbleText(
            enabled: selectable,
            onCopied: onCopied,
            child: LinkifiedText(
              text: body,
              style: TextStyle(color: textColor),
              // Both bubbles are tonal, so the brand colour has enough
              // contrast on either.
              linkColor: cs.primary,
              enableTaps: enableLinkTaps,
            ),
          ),
          if (previewUrl != null)
            LinkPreviewCard(url: previewUrl, onDark: isSent),
        ],
      ),
    );
  }
}

/// Makes the bubble body selectable while the long-press overlay has it
/// lifted, and leaves it untouched in the list.
///
/// It wraps the *same* [LinkifiedText] the flat bubble renders, inside a
/// [SelectionArea]. That is load-bearing: a `TextField`/`SelectableText` copy
/// lays out through `RenderEditable`, which reserves a caret margin, so the
/// text re-wrapped a line longer than the original and the lifted bubble ran
/// into the action menu. Same widget in, same wrapping out.
///
/// Nothing is selected when the overlay opens — the lift is *only* a zoom. A
/// long-press inside the lifted bubble then grabs the word under the finger
/// (SelectionArea's own word-granular gesture) and the handles widen it.
class SelectableBubbleText extends StatelessWidget {
  final Widget child;

  /// False in the list: the text is plain and the bubble owns the gestures.
  final bool enabled;

  /// Invoked after the toolbar's «کپی» so the overlay can dismiss.
  final VoidCallback? onCopied;

  const SelectableBubbleText({
    super.key,
    required this.child,
    required this.enabled,
    this.onCopied,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return SelectionArea(
      contextMenuBuilder: _selectionToolbar,
      child: child,
    );
  }

  /// Persian selection toolbar. The app ships no `MaterialLocalizations` for
  /// Persian, so the stock toolbar would read «Copy / Select all» — the
  /// framework's own button items are relabelled rather than re-implemented, so
  /// copying still goes through `SelectableRegion`.
  Widget _selectionToolbar(BuildContext context, SelectableRegionState state) {
    final items = <ContextMenuButtonItem>[];
    for (final item in state.contextMenuButtonItems) {
      switch (item.type) {
        case ContextMenuButtonType.copy:
          items.add(
            item.copyWith(
              label: 'کپی',
              onPressed: () {
                item.onPressed?.call();
                onCopied?.call();
              },
            ),
          );
        case ContextMenuButtonType.selectAll:
          items.add(item.copyWith(label: 'انتخاب همه'));
        // Share / search / lookup need platform plumbing this app doesn't
        // have — they are left out rather than shown broken.
        default:
          break;
      }
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }
}

/// A single chat bubble in the conversation list.
///
/// Bubbles are grouped (same sender within 2 min); [isLastInGroup] controls the
/// "tail" corner radius and [showTimestamp] whether the time + delivery status
/// row is rendered beneath the bubble. All interaction is delegated to the
/// callbacks so this widget stays presentation-only.
class MessageBubble extends StatefulWidget {
  final MessageModel message;
  final bool isLastInGroup;
  final bool showTimestamp;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;

  /// Long-press. Carries the bubble box's rect in global coordinates so the
  /// caller can lift a zoomed copy of it out of the list.
  final void Function(Rect anchor) onLongPress;
  final VoidCallback? onRetry;

  /// Whether a message containing a URL renders the link-preview card. Comes
  /// from «پیش‌نمایش خودکار پیوند» in Settings; passed in rather than read from
  /// a bloc so this widget stays presentation-only.
  final bool showLinkPreview;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isLastInGroup,
    required this.showTimestamp,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    this.onRetry,
    this.showLinkPreview = true,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  /// Measures the decorated box (not the padded row) — the overlay lifts
  /// exactly the bubble the finger was on.
  final GlobalKey _boxKey = GlobalKey();

  MessageModel get message => widget.message;

  /// The SIM to badge this bubble with, or null when there is nothing to say:
  /// a single-SIM phone, a card that has since been removed, or a row that was
  /// never stamped (everything sent or received before dual-SIM support).
  ///
  /// Read from the synchronous roster cache — a bubble may not await a platform
  /// channel inside `build`.
  SimCard? get _sim =>
      SimService.isMultiSim ? SimService.byId(message.subscriptionId) : null;

  void _handleLongPress() {
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    HapticFeedback.mediumImpact();
    widget.onLongPress(box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isSent = message.type == MessageType.sent;

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: _handleLongPress,
      child: Container(
        color: widget.selected ? cs.primary.withValues(alpha: 0.12) : null,
        padding: EdgeInsets.only(
          top: 1,
          bottom: widget.isLastInGroup ? 4 : 1,
          left: 8,
          right: 8,
        ),
        child: Column(
          crossAxisAlignment: isSent
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: isSent
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (widget.selectionMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 4, left: 4),
                    child: Icon(
                      widget.selected
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      size: 18,
                      color: widget.selected ? cs.primary : theme.dividerColor,
                    ),
                  ),
                Flexible(
                  child: MessageBubbleBody(
                    boxKey: _boxKey,
                    message: message,
                    isLastInGroup: widget.isLastInGroup,
                    showLinkPreview: widget.showLinkPreview,
                    enableLinkTaps: !widget.selectionMode,
                  ),
                ),
              ],
            ),
            if (widget.showTimestamp || message.status == MessageStatus.failed)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormatter.formatTime(message.timestamp),
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                    ),
                    // Which SIM carried it — only on a dual-SIM phone, and only
                    // when the row actually recorded one. A null subscription
                    // is "unknown", never SIM 1, so the badge is simply absent.
                    if (_sim != null) ...[
                      const SizedBox(width: 5),
                      SimBadge(sim: _sim!),
                    ],
                    if (isSent) ...[
                      const SizedBox(width: 6),
                      // Google labels the transport under the sent bubble.
                      Text(
                        'پیامک',
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                      ),
                      const SizedBox(width: 5),
                      _statusIcon(context),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(BuildContext context) {
    final theme = Theme.of(context);
    switch (message.status) {
      case MessageStatus.pending:
        return Icon(
          Icons.schedule,
          size: 13,
          color: theme.textTheme.bodySmall?.color,
        );
      case MessageStatus.sent:
        return Icon(
          Icons.check,
          size: 13,
          color: theme.textTheme.bodySmall?.color,
        );
      case MessageStatus.delivered:
        return Icon(
          Icons.done_all,
          size: 13,
          color: theme.textTheme.bodySmall?.color,
        );
      case MessageStatus.failed:
        return GestureDetector(
          onTap: widget.onRetry,
          child: const Icon(
            Icons.error_outline,
            size: 14,
            color: AppColors.danger,
          ),
        );
    }
  }
}

/// Circular send button shown at the trailing edge of the composer.
class MessageSendButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onSend;

  /// Long-press action: opens the «زمان‌بندی ارسال» sheet. Null disables the
  /// gesture.
  final VoidCallback? onSchedule;

  /// The composer is armed with a time, so tapping schedules instead of sends.
  final bool scheduled;

  const MessageSendButton({
    super.key,
    required this.enabled,
    required this.onSend,
    this.onSchedule,
    this.scheduled = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Tonal circle, matching the composer's «ارسال» affordance in Google
    // Messages (it is never a saturated fill).
    return Material(
      color: enabled
          ? cs.primaryContainer
          : cs.surfaceContainerHighest,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onSend : null,
        onLongPress: enabled && onSchedule != null ? onSchedule : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Icon(
            scheduled ? Icons.schedule_send : Icons.send,
            color: enabled ? cs.onPrimaryContainer : cs.onSurfaceVariant,
            size: 24,
          ),
        ),
      ),
    );
  }
}
