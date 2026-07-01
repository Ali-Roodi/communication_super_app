import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';

/// Long-press options for a single message (copy / forward / info / select /
/// delete). Each row pops the sheet, then invokes the matching callback.
Future<void> showMessageOptionsSheet(
  BuildContext context, {
  required VoidCallback onCopy,
  required VoidCallback onForward,
  required VoidCallback onInfo,
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
              leading: const Icon(Icons.copy_outlined),
              title: const Text('کپی'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onCopy();
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward_outlined),
              title: const Text('هدایت'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onForward();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('اطلاعات'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onInfo();
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
                'حذف',
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

/// Composer attachment sheet — the two functional rows (draft / template) plus
/// the placeholder media rows that report "coming soon".
Future<void> showAttachmentSheet(
  BuildContext context, {
  required VoidCallback onInsertDraft,
  required VoidCallback onInsertTemplate,
  required VoidCallback onSchedule,
  required VoidCallback onComingSoon,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('پیش‌نویس'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onInsertDraft();
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('قالب آماده'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onInsertTemplate();
              },
            ),
            ListTile(
              leading: const Icon(Icons.schedule_send_outlined),
              title: const Text('زمان‌بندی ارسال'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onSchedule();
              },
            ),
            const Divider(height: 1),
            for (final item in const [
              (Icons.photo_camera_outlined, 'دوربین'),
              (Icons.photo_library_outlined, 'گالری'),
              (Icons.mic_none_outlined, 'صدا'),
              (Icons.location_on_outlined, 'موقعیت'),
            ])
              ListTile(
                leading: Icon(item.$1),
                title: Text(item.$2),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onComingSoon();
                },
              ),
          ],
        ),
      ),
    ),
  );
}
