import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import '../../models/message_model.dart';

/// Single-thread long-press options sheet (pin, mark read/unread, archive,
/// block, select, delete).
///
/// Presentation-only: each row pops the sheet and then invokes the matching
/// callback, which `MessagesListScreen` wires to the relevant BLoC action.
Future<void> showThreadOptionsSheet(
  BuildContext context, {
  required MessageThread thread,
  required VoidCallback onTogglePin,
  required VoidCallback onToggleRead,
  required VoidCallback onArchive,
  required VoidCallback onBlock,
  required VoidCallback onSelect,
  required VoidCallback onDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                thread.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              title: Text(thread.isPinned ? 'برداشتن سنجاق' : 'سنجاق کردن'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onTogglePin();
              },
            ),
            ListTile(
              leading: Icon(
                thread.hasUnread
                    ? Icons.mark_chat_read_outlined
                    : Icons.mark_chat_unread_outlined,
              ),
              title: Text(
                thread.hasUnread
                    ? 'علامت‌گذاری خوانده‌شده'
                    : 'علامت‌گذاری نخوانده',
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                onToggleRead();
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('بایگانی'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onArchive();
              },
            ),
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('مسدود کردن و گزارش هرزنامه'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onBlock();
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('انتخاب'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onSelect();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.danger,
              ),
              title: const Text(
                'حذف گفتگو',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                onDelete();
              },
            ),
          ],
        ),
      ),
    ),
  );
}
