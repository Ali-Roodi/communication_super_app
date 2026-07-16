import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import '../../models/message_model.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isSent = message.type == MessageType.sent;

    final bubbleColor = isSent ? cs.primary : cs.surfaceContainerHighest;
    final textColor = isSent ? cs.onPrimary : cs.onSurface;

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
                    child: Text(
                      message.body,
                      style: TextStyle(color: textColor),
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
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                    if (isSent) ...[
                      const SizedBox(width: 4),
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

  /// Long-press action: opens the scheduler prefilled with the composer text
  /// (ارسال زمان‌بندی‌شده). Null disables the gesture.
  final VoidCallback? onSchedule;

  const MessageSendButton({
    super.key,
    required this.enabled,
    required this.onSend,
    this.onSchedule,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: enabled ? cs.primary : cs.primary.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onSend : null,
        onLongPress: enabled && onSchedule != null ? onSchedule : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(Icons.send, color: cs.onPrimary, size: 24),
        ),
      ),
    );
  }
}
