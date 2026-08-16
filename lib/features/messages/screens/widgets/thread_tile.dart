import 'package:flutter/material.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/models/template_wire.dart';

/// A single conversation row, laid out like Google Messages: avatar · name over
/// a two-line snippet · date and the unread badge stacked at the end.
///
/// Rows are flat — the surrounding list already sits on the rounded sheet — so
/// unread state is carried by weight, not by a tinted background. Selecting a
/// row (multi-select) turns the avatar into a check and wraps the row in a
/// stadium highlight, exactly as Google Messages does.
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
    final scheme = Theme.of(context).colorScheme;
    final unread = thread.hasUnread;
    final name = _displayName;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLeading(context, name),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (thread.isPinned)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(end: 4),
                              child: Icon(
                                Icons.push_pin,
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                height: 1.3,
                                fontWeight: unread
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      _snippet(context, unread),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      DateFormatter.formatRelative(thread.sortTime),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
                        color: unread
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    if (unread) ...[
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(minWidth: 22),
                        height: 22,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          PersianUtils.toPersianNumber('${thread.unreadCount}'),
                          style: TextStyle(
                            color: scheme.onPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _snippet(BuildContext context, bool unread) {
    final scheme = Theme.of(context).colorScheme;
    if (thread.hasDraft) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'پیش‌نویس: ',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.error,
              ),
            ),
            TextSpan(
              text: thread.draftText!.replaceAll('\n', ' '),
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text(
      // A template message is stored as its compact wire payload; the preview
      // shows the rebuilt text, never the payload (see [TemplateWire]).
      TemplateWire.displayText(thread.lastMessage),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 14,
        height: 1.35,
        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
        color: unread ? scheme.onSurface : scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildLeading(BuildContext context, String name) {
    final scheme = Theme.of(context).colorScheme;
    if (selected) {
      return CircleAvatar(
        radius: 24,
        backgroundColor: scheme.primary,
        child: Icon(Icons.check, color: scheme.onPrimary),
      );
    }
    // Contact photo when the number is saved, initials otherwise — same 48 dp
    // box either way, so the row height (and the list's item extent) is
    // unchanged. The `selected` check above still wins.
    return PhoneContactAvatar(
      phoneNumber: thread.phoneNumber,
      name: name,
      size: 48,
    );
  }
}
