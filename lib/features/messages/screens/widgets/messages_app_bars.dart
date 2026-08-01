import 'package:flutter/material.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';

/// The inbox headers, as **slivers** so the default one can collapse the way
/// Google Messages' does: a tall, centred title that shrinks into a compact bar
/// as the conversation sheet scrolls up under it.
///
/// Presentation-only: every action is a callback owned by
/// `MessagesListScreen`, which holds the search/selection state.
class MessagesDefaultAppBar extends StatelessWidget {
  const MessagesDefaultAppBar({
    super.key,
    required this.onSearch,
    required this.onOpenArchived,
    required this.onOpenDrafts,
    required this.onOpenTemplates,
    required this.onOpenScheduled,
    required this.onOpenSettings,
    required this.onOpenStarred,
  });

  final VoidCallback onSearch;
  final VoidCallback onOpenArchived;
  final VoidCallback onOpenDrafts;
  final VoidCallback onOpenTemplates;
  final VoidCallback onOpenScheduled;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenStarred;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      expandedHeight: 168,
      collapsedHeight: kToolbarHeight,
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      flexibleSpace: FlexibleSpaceBar(
        centerTitle: true,
        titlePadding: const EdgeInsetsDirectional.only(
          start: 16,
          end: 16,
          bottom: 14,
        ),
        title: Text(
          'پیام‌ها',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w400,
            color: scheme.onSurface,
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'جستجو',
          onPressed: onSearch,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'گزینه‌های بیشتر',
          position: PopupMenuPosition.under,
          onSelected: (v) {
            switch (v) {
              case 'starred':
                onOpenStarred();
              case 'archived':
                onOpenArchived();
              case 'drafts':
                onOpenDrafts();
              case 'templates':
                onOpenTemplates();
              case 'scheduled':
                onOpenScheduled();
              case 'settings':
                onOpenSettings();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'starred', child: Text('ستاره‌دار')),
            PopupMenuItem(value: 'archived', child: Text('بایگانی')),
            PopupMenuItem(value: 'drafts', child: Text('پیش‌نویس‌ها')),
            PopupMenuItem(value: 'templates', child: Text('قالب‌های آماده')),
            PopupMenuItem(value: 'scheduled', child: Text('زمان‌بندی‌شده‌ها')),
            PopupMenuItem(value: 'settings', child: Text('تنظیمات')),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// The inline-search header shown while searching the inbox.
class MessagesSearchAppBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        icon: const Icon(Icons.arrow_forward),
        onPressed: onBack,
      ),
      title: TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: 16, color: scheme.onSurface),
        decoration: const InputDecoration(
          hintText: 'جستجو در پیام‌ها',
          filled: false,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
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

/// The contextual header shown while one or more threads are multi-selected —
/// count on the leading side, the frequent actions inline, the rest behind the
/// overflow, mirroring Google Messages' selection bar.
class MessagesSelectionAppBar extends StatelessWidget {
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
    required this.onPin,
  });

  final int selectedCount;
  final VoidCallback onClear;
  final VoidCallback onMarkRead;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final VoidCallback onSelectAll;
  final VoidCallback onMarkUnread;
  final VoidCallback onBlock;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(icon: const Icon(Icons.close), onPressed: onClear),
      title: Text(PersianUtils.toPersianNumber('$selectedCount')),
      actions: [
        IconButton(
          icon: const Icon(Icons.push_pin_outlined),
          tooltip: 'سنجاق',
          onPressed: onPin,
        ),
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
          icon: const Icon(Icons.more_vert),
          position: PopupMenuPosition.under,
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
        const SizedBox(width: 4),
      ],
    );
  }
}
