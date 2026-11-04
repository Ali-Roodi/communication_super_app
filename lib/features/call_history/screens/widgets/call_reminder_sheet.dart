import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/undo_snack_bar.dart';
import 'package:communication_super_app/features/hidden/widgets/hidden_entries.dart';
import 'package:communication_super_app/features/messages/screens/widgets/schedule_send_sheet.dart';

import '../../services/call_reminders.dart';

/// One tap's worth of «when» on the reminder sheet.
class ReminderTime {
  const ReminderTime(this.label, this.at);

  final String label;
  final DateTime at;
}

/// The one-tap times offered at [now]. «امروز عصر» only while 18:00 is more than
/// an hour off: closer than that, «۱ ساعت دیگر» already says it.
List<ReminderTime> reminderQuickTimes(DateTime now) {
  final evening = DateTime(now.year, now.month, now.day, 18);
  final tomorrow = now.add(const Duration(days: 1));
  return [
    ReminderTime('۱۵ دقیقه دیگر', now.add(const Duration(minutes: 15))),
    ReminderTime('۱ ساعت دیگر', now.add(const Duration(hours: 1))),
    ReminderTime('۳ ساعت دیگر', now.add(const Duration(hours: 3))),
    if (evening.isAfter(now.add(const Duration(hours: 1))))
      ReminderTime('امروز عصر', evening),
    ReminderTime(
      'فردا صبح',
      DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 8),
    ),
  ];
}

/// Asks what and when, sets the reminder and says so.
Future<void> setCallReminder(
  BuildContext context, {
  required String phone,
  String? name,
}) async {
  final title = name?.isNotEmpty == true
      ? name!
      : PersianUtils.displayPhone(phone);
  final choice = await _showSheet(context, title: title);
  if (choice == null) return;

  final reminders = CallReminders.instance;
  final saved = await reminders.add(
    number: phone,
    kind: choice.kind,
    at: choice.at,
    name: name?.isNotEmpty == true ? name : null,
  );
  final alerts = await reminders.alertsEnabled();
  if (!context.mounted) return;
  if (saved == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('یادآور ثبت نشد')));
    return;
  }
  final when = formatScheduleLabel(saved.at);
  showUndoSnack(
    context,
    message: alerts
        ? 'یادآور ${_kindName(saved.kind)}: $when'
        : 'یادآور ثبت شد، ولی اعلان‌های برنامه خاموش است و هشداری نمی‌آید',
    onUndo: () => reminders.remove(saved.id),
  );
}

String _kindName(CallReminderKind kind) =>
    kind == CallReminderKind.call ? 'تماس' : 'پیامک';

IconData _kindIcon(CallReminderKind kind) => kind == CallReminderKind.call
    ? Icons.call_outlined
    : Icons.chat_bubble_outline;

Future<({CallReminderKind kind, DateTime at})?> _showSheet(
  BuildContext context, {
  required String title,
}) {
  var kind = CallReminderKind.call;
  final now = DateTime.now();

  return showModalBottomSheet<({CallReminderKind kind, DateTime at})>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        final theme = Theme.of(sheetCtx);

        Future<void> pickDateTime() async {
          final picked = await pickScheduleDateTime(sheetCtx, DateTime.now());
          if (!sheetCtx.mounted || picked == null) return;
          if (!picked.isAfter(DateTime.now())) {
            ScaffoldMessenger.of(sheetCtx).showSnackBar(
              const SnackBar(content: Text('زمان انتخاب‌شده گذشته است')),
            );
            return;
          }
          Navigator.pop(sheetCtx, (kind: kind, at: picked));
        }

        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                    child: Text(
                      'یادآور برای $title',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SegmentedButton<CallReminderKind>(
                      segments: [
                        for (final k in CallReminderKind.values)
                          ButtonSegment(
                            value: k,
                            icon: Icon(_kindIcon(k)),
                            label: Text(_kindName(k)),
                          ),
                      ],
                      selected: {kind},
                      onSelectionChanged: (s) =>
                          setSheetState(() => kind = s.first),
                    ),
                  ),
                  for (final option in reminderQuickTimes(now))
                    ListTile(
                      leading: const Icon(Icons.schedule_outlined),
                      title: Text(option.label),
                      trailing: Text(
                        formatScheduleLabel(option.at),
                        style: theme.textTheme.bodyMedium,
                      ),
                      onTap: () =>
                          Navigator.pop(sheetCtx, (kind: kind, at: option.at)),
                    ),
                  ListTile(
                    leading: const Icon(Icons.event_outlined),
                    title: const Text('انتخاب تاریخ و ساعت'),
                    onTap: pickDateTime,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// «یادآورها» at the top of «اخیر», only while there is one.
class CallRemindersEntry extends StatelessWidget {
  const CallRemindersEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<CallReminder>>(
      valueListenable: CallReminders.instance.pending,
      builder: (context, pending, _) {
        if (pending.isEmpty) return const SizedBox.shrink();
        return SecureEntryRow(
          icon: Icons.alarm_outlined,
          title: 'یادآورها',
          trailing: PersianUtils.toPersianNumber('${pending.length}'),
          onTap: () => _showPending(context),
        );
      },
    );
  }

  Future<void> _showPending(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: ValueListenableBuilder<List<CallReminder>>(
            valueListenable: CallReminders.instance.pending,
            builder: (sheetCtx, pending, _) {
              if (pending.isEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (sheetCtx.mounted) Navigator.maybePop(sheetCtx);
                });
                return const SizedBox(height: 56);
              }
              return ListView.builder(
                shrinkWrap: true,
                itemCount: pending.length,
                itemBuilder: (_, index) => _PendingRow(pending[index]),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow(this.reminder);

  final CallReminder reminder;

  @override
  Widget build(BuildContext context) {
    final name = reminder.name;
    return ListTile(
      leading: Icon(_kindIcon(reminder.kind)),
      title: name != null
          ? Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)
          : Text(
              PersianUtils.displayPhone(reminder.number),
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.start,
            ),
      subtitle: Text(
        '${_kindName(reminder.kind)} · ${formatScheduleLabel(reminder.at)}',
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'حذف یادآور',
        onPressed: () => CallReminders.instance.remove(reminder.id),
      ),
    );
  }
}
