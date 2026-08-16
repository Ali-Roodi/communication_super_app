import 'package:flutter/material.dart';
import '../../models/template_wire.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import '../../models/scheduled_message_model.dart';
import 'schedule_send_sheet.dart';

/// A not-yet-sent scheduled message, rendered inline at the end of the
/// conversation (Google Messages style).
///
/// Deliberately *unlike* a normal sent bubble: outlined instead of filled, with
/// a clock header carrying the send time, so it reads as "queued" at a glance.
/// Once delivered, the schedule disappears from [ScheduledMessageBloc] and the
/// real message takes its place as an ordinary bubble.
class ScheduledBubble extends StatelessWidget {
  final ScheduledMessage message;
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  const ScheduledBubble({
    super.key,
    required this.message,
    required this.onLongPress,
    required this.onTap,
  });

  /// «ارسال در ۱۴:۳۰» / «ارسال در فردا، ۰۸:۰۰» — today's schedules only need
  /// the time; anything further out names the day the way the composer banner
  /// and the options sheet do.
  String _sendAtLabel() {
    final at = message.scheduledAt;
    final now = DateTime.now();
    final isToday =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final when = isToday
        ? PersianUtils.toPersianNumber(DateFormatter.formatTime(at))
        : formatScheduleLabel(at);
    return 'ارسال در $when';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sending = message.status == ScheduleStatus.sending;
    final retrying = message.attemptCount > 0;

    return GestureDetector(
      // Opaque: the bubble is right-aligned inside a full-width column, so the
      // empty space beside it must still take the press (as in Google Messages).
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4, left: 8, right: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.06),
                border: Border.all(
                  color: cs.primary.withValues(alpha: 0.45),
                  width: 1.2,
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(theme, sending: sending, retrying: retrying),
                  const SizedBox(height: 6),
                  Text(
                    // A scheduled template holds its compact payload — show
                    // the message, not the wire (see TemplateWire).
                    TemplateWire.displayText(message.body),
                    style: TextStyle(color: cs.onSurface),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
              child: Text(
                'برای گزینه‌ها نگه دارید',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: theme.textTheme.bodySmall?.color?.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(
    ThemeData theme, {
    required bool sending,
    required bool retrying,
  }) {
    final cs = theme.colorScheme;
    final Color color;
    final IconData icon;
    final String label;
    if (sending) {
      color = cs.primary;
      icon = Icons.send_outlined;
      label = 'در حال ارسال…';
    } else if (retrying) {
      color = AppColors.callHoldOrange;
      icon = Icons.refresh;
      label = 'تلاش مجدد — $_retryLabel';
    } else {
      color = cs.primary;
      icon = Icons.schedule;
      label = _sendAtLabel();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            PersianUtils.toPersianNumber(label),
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  String get _retryLabel {
    final at = message.nextAttemptAt;
    if (at == null) return 'به‌زودی';
    return DateFormatter.formatTime(at);
  }
}
