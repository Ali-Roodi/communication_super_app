import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import '../../models/message_model.dart';
import 'link_preview_card.dart';
import 'linkified_text.dart';

/// A single chat bubble in the conversation list.
///
/// Bubbles are grouped (same sender within 2 min); [isLastInGroup] controls the
/// "tail" corner radius and [showTimestamp] whether the time + delivery status
/// row is rendered beneath the bubble. All interaction is delegated to the
/// callbacks so this widget stays presentation-only.
class MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isLastInGroup;
  final bool showTimestamp;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
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

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? cs.primary.withValues(alpha: 0.12) : null,
        padding: EdgeInsets.only(
          top: 1,
          bottom: isLastInGroup ? 4 : 1,
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
                if (selectionMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 4, left: 4),
                    child: Icon(
                      selected ? Icons.check_circle : Icons.circle_outlined,
                      size: 18,
                      color: selected ? cs.primary : theme.dividerColor,
                    ),
                  ),
                Flexible(
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: radius,
                    ),
                    child: Builder(
                      builder: (context) {
                        final previewUrl = showLinkPreview
                            ? LinkifiedText.firstUrl(message.body)
                            : null;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LinkifiedText(
                              text: message.body,
                              style: TextStyle(color: textColor),
                              // Both bubbles are tonal, so the brand colour has
                              // enough contrast on either.
                              linkColor: cs.primary,
                              enableTaps: !selectionMode,
                            ),
                            if (previewUrl != null)
                              LinkPreviewCard(url: previewUrl, onDark: isSent),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
            if (showTimestamp || message.status == MessageStatus.failed)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormatter.formatTime(message.timestamp),
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                    ),
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
          onTap: onRetry,
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
