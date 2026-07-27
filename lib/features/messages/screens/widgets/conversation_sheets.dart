import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import '../../models/scheduled_message_model.dart';
import 'schedule_send_sheet.dart';

/// Long-press options for a pending scheduled message shown inside the chat —
/// the Google Messages set: send now / reschedule / copy / cancel schedule.
///
/// "Cancel" keeps the row as history (`cancelled`); "delete" removes it. Both
/// are offered because the schedules list surfaces the history section.
Future<void> showScheduledMessageOptionsSheet(
  BuildContext context, {
  required ScheduledMessage message,
  required VoidCallback onSendNow,
  required VoidCallback onReschedule,
  required VoidCallback onCopy,
  required VoidCallback onDelete,
}) {
  final sending = message.status == ScheduleStatus.sending;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ScheduledSheetHeader(message: message),
            const Divider(height: 1),
            ListTile(
              enabled: !sending,
              leading: const Icon(Icons.send),
              title: const Text('ارسال فوری'),
              subtitle: sending ? const Text('در حال ارسال…') : null,
              onTap: () {
                Navigator.pop(sheetCtx);
                onSendNow();
              },
            ),
            ListTile(
              enabled: !sending,
              leading: const Icon(Icons.schedule_outlined),
              title: const Text('تغییر زمان'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onReschedule();
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('کپی متن'),
              onTap: () {
                Navigator.pop(sheetCtx);
                onCopy();
              },
            ),
            ListTile(
              enabled: !sending,
              leading: const Icon(
                Icons.cancel_schedule_send_outlined,
                color: AppColors.danger,
              ),
              title: const Text(
                'لغو زمان‌بندی',
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

/// Recipient + send time header at the top of the scheduled-message sheet.
class _ScheduledSheetHeader extends StatelessWidget {
  final ScheduledMessage message;
  const _ScheduledSheetHeader({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.schedule, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                PersianUtils.toPersianNumber(
                  formatScheduleLabel(message.scheduledAt),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Long-press options for a single message (star / copy / forward / info /
/// select / delete). Each row pops the sheet, then invokes the matching
/// callback.
Future<void> showMessageOptionsSheet(
  BuildContext context, {
  required VoidCallback onCopy,
  required VoidCallback onSelectText,
  required VoidCallback onForward,
  required VoidCallback onInfo,
  required VoidCallback onSelect,
  required VoidCallback onDelete,
  required VoidCallback onToggleStar,
  required bool isStarred,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        // Scrollable: six rows no longer fit short viewports (landscape,
        // small screens) — without this the sheet overflows.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  isStarred ? Icons.star : Icons.star_border,
                  color: isStarred ? AppColors.callHoldOrange : null,
                ),
                title: Text(
                  isStarred ? 'حذف از ستاره‌دارها' : 'افزودن به ستاره‌دارها',
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onToggleStar();
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('کپی'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onCopy();
                },
              ),
              ListTile(
                leading: const Icon(Icons.text_fields_outlined),
                title: const Text('انتخاب متن'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onSelectText();
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
