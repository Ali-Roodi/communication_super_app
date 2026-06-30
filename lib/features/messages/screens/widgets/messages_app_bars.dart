import 'package:flutter/material.dart';

/// The default inbox app bar (title + search + overflow menu).
///
/// Presentation-only: every action is a callback owned by
/// `MessagesListScreen`, which holds the search/selection state.
class MessagesDefaultAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const MessagesDefaultAppBar({
    super.key,
    required this.onSearch,
    required this.onOpenArchived,
    required this.onOpenDrafts,
    required this.onOpenSettings,
  });

  final VoidCallback onSearch;
  final VoidCallback onOpenArchived;
  final VoidCallback onOpenDrafts;
  final VoidCallback onOpenSettings;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: const Text('پیام‌ها'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'جستجو',
          onPressed: onSearch,
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'archived':
                onOpenArchived();
              case 'drafts':
                onOpenDrafts();
              case 'settings':
                onOpenSettings();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'archived', child: Text('بایگانی')),
            PopupMenuItem(value: 'drafts', child: Text('پیش‌نویس‌ها')),
            PopupMenuItem(value: 'settings', child: Text('تنظیمات')),
          ],
        ),
      ],
    );
  }
}

/// The inline-search app bar shown while searching the inbox.
class MessagesSearchAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const MessagesSearchAppBar({
    super.key,
    required this.controller,
    required this.showClear,
    required this.onBack,
    required this.onClear,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool showClear;
  final VoidCallback onBack;
  final VoidCallback onClear;
  final ValueChanged<String> onChanged;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_forward),
        onPressed: onBack,
      ),
      title: TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: 'جستجو در پیام‌ها',
          border: InputBorder.none,
        ),
        onChanged: onChanged,
      ),
      actions: [
        if (showClear)
          IconButton(icon: const Icon(Icons.close), onPressed: onClear),
      ],
    );
  }
}

/// The contextual app bar shown while one or more threads are multi-selected.
class MessagesSelectionAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const MessagesSelectionAppBar({
    super.key,
    required this.selectedCount,
    required this.onClear,
    required this.onMarkRead,
    required this.onArchive,
    required this.onDelete,
    required this.onSelectAll,
    required this.onMarkUnread,
    required this.onBlock,
  });

  final int selectedCount;
  final VoidCallback onClear;
  final VoidCallback onMarkRead;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final VoidCallback onSelectAll;
  final VoidCallback onMarkUnread;
  final VoidCallback onBlock;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: onClear),
      title: Text('$selectedCount'),
      actions: [
        IconButton(
          icon: const Icon(Icons.mark_chat_read_outlined),
          tooltip: 'علامت‌گذاری خوانده‌شده',
          onPressed: onMarkRead,
        ),
        IconButton(
          icon: const Icon(Icons.archive_outlined),
          tooltip: 'بایگانی',
          onPressed: onArchive,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'حذف',
          onPressed: onDelete,
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'select_all':
                onSelectAll();
              case 'mark_unread':
                onMarkUnread();
              case 'block':
                onBlock();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'select_all', child: Text('انتخاب همه')),
            PopupMenuItem(
              value: 'mark_unread',
              child: Text('علامت‌گذاری نخوانده'),
            ),
            PopupMenuItem(value: 'block', child: Text('مسدود کردن')),
          ],
        ),
      ],
    );
  }
}
