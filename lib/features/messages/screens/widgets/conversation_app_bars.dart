import 'package:flutter/material.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
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
    required this.onMenuSelected,
  });

  final String title;
  final String phoneNumber;
  final bool hasName;
  final VoidCallback onOpenContact;
  final VoidCallback onCall;
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
            AvatarWidget(name: title, size: 36),
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
                    Text(
                      PhoneNormalizer.toNational(phoneNumber),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.call_outlined),
          tooltip: 'تماس',
          onPressed: onCall,
        ),
        PopupMenuButton<String>(
          onSelected: onMenuSelected,
          itemBuilder: (_) => [
            if (hasName)
              const PopupMenuItem(value: 'view', child: Text('مشاهده مخاطب'))
            else
              const PopupMenuItem(
                value: 'add',
                child: Text('افزودن به مخاطبین'),
              ),
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
      title: Text('$selectedCount'),
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
