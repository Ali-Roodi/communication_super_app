import 'package:flutter/material.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';

/// A single conversation row in Google Messages style.
///
/// - Unread: bold title, primary-colored timestamp, unread-count badge,
///   primary ring around the avatar, slightly elevated (surfaceVariant) tile.
/// - Selected (multi-select mode): checkmark avatar + highlighted background.
class ThreadTile extends StatelessWidget {
  final MessageThread thread;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const ThreadTile({
    super.key,
    required this.thread,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
  });

  String get _displayName => thread.contactName?.isNotEmpty == true
      ? thread.contactName!
      : PersianUtils.displayPhone(
          PhoneNormalizer.toNational(thread.phoneNumber),
        );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final unread = thread.hasUnread;
    final name = _displayName;

    final Color? tileColor = selected
        ? cs.primary.withValues(alpha: 0.14)
        : (unread ? cs.surfaceContainerHighest.withValues(alpha: 0.5) : null);

    return Material(
      color: tileColor ?? Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              _buildLeading(context, name, unread),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (thread.isPinned)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.push_pin,
                              size: 14,
                              color: theme.textTheme.bodyMedium?.color,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: unread
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: theme.textTheme.bodyLarge?.color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          DateFormatter.formatRelative(thread.sortTime),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: unread
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: unread
                                ? cs.primary
                                : theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: thread.hasDraft
                              ? Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: 'پیش‌نویس: ',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: cs.error,
                                        ),
                                      ),
                                      TextSpan(
                                        text: thread.draftText!.replaceAll(
                                          '\n',
                                          ' ',
                                        ),
                                        style: TextStyle(
                                          fontSize: 14,
                                          color:
                                              theme.textTheme.bodyMedium?.color,
                                        ),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : Text(
                                  thread.lastMessage,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: unread
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: unread
                                        ? theme.textTheme.bodyLarge?.color
                                        : theme.textTheme.bodyMedium?.color,
                                  ),
                                ),
                        ),
                        if (unread) ...[
                          const SizedBox(width: 8),
                          Container(
                            constraints: const BoxConstraints(minWidth: 20),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${thread.unreadCount}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeading(BuildContext context, String name, bool unread) {
    final cs = Theme.of(context).colorScheme;
    if (selected) {
      return CircleAvatar(
        radius: 24,
        backgroundColor: cs.primary,
        child: const Icon(Icons.check, color: Colors.white),
      );
    }
    if (unread) {
      // Colored ring around the avatar for unread threads.
      return Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: cs.primary, width: 2),
        ),
        child: AvatarWidget(name: name, size: 44),
      );
    }
    return AvatarWidget(name: name, size: 48);
  }
}
