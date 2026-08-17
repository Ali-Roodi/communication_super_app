import 'package:flutter/material.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';

/// The conversation header (avatar + name/number, call button, overflow menu).
///
/// Presentation-only: `onMenuSelected` receives the raw menu value
/// (`view` / `add` / `block` / `delete`) for the screen to dispatch.
class ConversationAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const ConversationAppBar({
    super.key,
    required this.title,
    required this.phoneNumber,
    required this.hasName,
    required this.onOpenContact,
    required this.onCall,
    this.onCallPickingSim,
    required this.onMenuSelected,
  });

  final String title;
  final String phoneNumber;
  final bool hasName;
  final VoidCallback onOpenContact;
  final VoidCallback onCall;

  /// Long-press on the call button — choose the SIM for this one call. Null on
  /// a single-SIM phone, where the gesture would do nothing.
  final VoidCallback? onCallPickingSim;

  final ValueChanged<String> onMenuSelected;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBar(
      titleSpacing: 0,
      title: InkWell(
        onTap: onOpenContact,
        child: Row(
          children: [
            // The saved contact's photo when this number belongs to one — the
            // same avatar the address book draws. Resolution is O(1) on the
            // warm number index and only this 36 dp box rebuilds if it lands
            // late, so the header never waits on the address book.
            PhoneContactAvatar(phoneNumber: phoneNumber, name: title, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17),
                  ),
                  if (hasName)
                    // Right-aligned under the name (RTL start). The number still
                    // reads left-to-right — displayPhone wraps it in an LTR
                    // embedding — so it's «0919 096 1805», just anchored right.
                    Text(
                      PersianUtils.displayPhone(
                        PhoneNormalizer.toNational(phoneNumber),
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        GestureDetector(
          onLongPress: onCallPickingSim,
          child: IconButton(
            icon: const Icon(Icons.call_outlined),
            tooltip: onCallPickingSim == null
                ? 'تماس'
                : 'تماس · نگه‌داشتن برای انتخاب سیم‌کارت',
            onPressed: onCall,
          ),
        ),
        PopupMenuButton<String>(
          onSelected: onMenuSelected,
          itemBuilder: (_) => [
            if (hasName)
              const PopupMenuItem(value: 'view', child: Text('مشاهده مخاطب'))
            else ...[
              const PopupMenuItem(
                value: 'add',
                child: Text('ایجاد مخاطب جدید'),
              ),
              const PopupMenuItem(
                value: 'addExisting',
                child: Text('افزودن به مخاطب موجود'),
              ),
            ],
            // The discoverable half of the pinch gesture on the thread — a
            // two-finger gesture is not something the person who needs bigger
            // text is going to find on their own.
            const PopupMenuItem(value: 'textSize', child: Text('اندازه متن')),
            const PopupMenuItem(
              value: 'block',
              child: Text('مسدود کردن و گزارش هرزنامه'),
            ),
            const PopupMenuItem(value: 'delete', child: Text('حذف گفتگو')),
          ],
        ),
      ],
    );
  }
}

/// The header of a **group** conversation.
///
/// A separate widget rather than a pile of `if (isGroup)` inside
/// [ConversationAppBar], because almost nothing survives the change: a group has
/// no photo, no number to print, nobody to call, no contact to open and nothing
/// to block. What it has instead is a member count and a details page — so those
/// are what the header shows.
class GroupConversationAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const GroupConversationAppBar({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onOpenDetails,
    required this.onMenuSelected,
  });

  final String title;

  /// «۴ نفر» — the one fact about a group that fits under its name.
  final String subtitle;

  final VoidCallback onOpenDetails;
  final ValueChanged<String> onMenuSelected;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AppBar(
      titleSpacing: 0,
      title: InkWell(
        onTap: onOpenDetails,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.group_outlined,
                size: 20,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17),
                  ),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        PopupMenuButton<String>(
          onSelected: onMenuSelected,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'details', child: Text('جزئیات گروه')),
            PopupMenuItem(value: 'textSize', child: Text('اندازه متن')),
            PopupMenuItem(value: 'delete', child: Text('حذف گفتگو')),
          ],
        ),
      ],
    );
  }
}

/// The contextual app bar shown while messages are multi-selected.
class ConversationSelectionAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const ConversationSelectionAppBar({
    super.key,
    required this.selectedCount,
    required this.onClear,
    required this.onCopy,
    required this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onClear;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: onClear),
      title: Text(PersianUtils.toPersianNumber('$selectedCount')),
      actions: [
        IconButton(
          icon: const Icon(Icons.copy_outlined),
          tooltip: 'کپی',
          onPressed: onCopy,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'حذف',
          onPressed: onDelete,
        ),
      ],
    );
  }
}
