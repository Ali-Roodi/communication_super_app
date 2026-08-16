import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/jalali_date_picker.dart';
import '../../models/scheduled_message_model.dart';

/// Everything the «زمان‌بندی ارسال» sheet hands back: the moment to send, plus
/// the repeat rule the schedule keeps firing on.
class ScheduleChoice {
  final DateTime at;
  final ScheduleRepeat repeat;
  final int repeatEvery;
  final Set<int> weekdays;
  final JitterWindow jitter;
  final ScheduleEnd endType;
  final DateTime? endDate;
  final int? maxOccurrences;

  const ScheduleChoice({
    required this.at,
    this.repeat = ScheduleRepeat.none,
    this.repeatEvery = 1,
    this.weekdays = const {},
    this.jitter = JitterWindow.none,
    this.endType = ScheduleEnd.never,
    this.endDate,
    this.maxOccurrences,
  });

  ScheduleChoice copyWith({
    DateTime? at,
    ScheduleRepeat? repeat,
    int? repeatEvery,
    Set<int>? weekdays,
    JitterWindow? jitter,
    ScheduleEnd? endType,
    DateTime? endDate,
    int? maxOccurrences,
    bool clearEndDate = false,
    bool clearMaxOccurrences = false,
  }) => ScheduleChoice(
    at: at ?? this.at,
    repeat: repeat ?? this.repeat,
    repeatEvery: repeatEvery ?? this.repeatEvery,
    weekdays: weekdays ?? this.weekdays,
    jitter: jitter ?? this.jitter,
    endType: endType ?? this.endType,
    endDate: clearEndDate ? null : (endDate ?? this.endDate),
    maxOccurrences: clearMaxOccurrences
        ? null
        : (maxOccurrences ?? this.maxOccurrences),
  );

  /// Seeds the sheet from a schedule that already exists (reschedule).
  factory ScheduleChoice.fromMessage(ScheduledMessage m) => ScheduleChoice(
    at: m.scheduledAt,
    repeat: m.repeat,
    repeatEvery: m.repeatEvery,
    weekdays: m.weekdays,
    jitter: m.jitter,
    endType: m.endType,
    endDate: m.endDate,
    maxOccurrences: m.maxOccurrences,
  );
}

/// Google Messages' «Schedule send» sheet: one-tap times plus a full date/time
/// pick, opened by long-pressing the send button, from the «+» sheet, or by
/// tapping the composer's schedule banner to edit an armed schedule.
///
/// Returns the choice, or null when the user backed out. Nothing is scheduled
/// here — the caller arms the composer and the save happens on send, exactly
/// like Google. The repeat / jitter / end rules live in the same sheet: there
/// is deliberately no separate scheduling screen.
///
/// Two ways out, on purpose:
/// * a **quick time** pops straight away (Google's one-tap flow), carrying
///   whatever repeat/jitter was configured first;
/// * «انتخاب تاریخ و ساعت» only *sets* the time and keeps the sheet open, so
///   the rules below it stay reachable and «تأیید» closes.
///
/// The second path is what makes editing work: re-opened from the banner the
/// sheet already has a time, so the user can change only the jitter and
/// confirm without being forced to re-pick the moment.
Future<ScheduleChoice?> showScheduleSendSheet(
  BuildContext context, {
  ScheduleChoice? initial,
}) {
  final now = DateTime.now();
  var choice = initial ?? ScheduleChoice(at: _defaultTime(now));
  // A fresh sheet has no moment yet (`at` is just "now" so the pickers open
  // where the user is), so there is nothing to confirm until one is picked.
  var hasTime = initial != null;

  return showModalBottomSheet<ScheduleChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        final theme = Theme.of(sheetCtx);

        Future<void> pickDateTime() async {
          final picked = await _pickDateTime(sheetCtx, choice.at);
          if (!sheetCtx.mounted || picked == null) return;
          // The pickers open on "now", so a couple of taps can land in the
          // past; sending then happens instantly, which is never what
          // «زمان‌بندی» meant.
          if (!picked.isAfter(DateTime.now())) {
            ScaffoldMessenger.of(sheetCtx).showSnackBar(
              const SnackBar(content: Text('زمان انتخاب‌شده گذشته است')),
            );
            return;
          }
          setSheetState(() {
            choice = choice.copyWith(at: picked);
            hasTime = true;
          });
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
                      'زمان‌بندی ارسال',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (hasTime) ...[
                    ListTile(
                      leading: Icon(
                        Icons.event_available_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      title: const Text('زمان ارسال'),
                      subtitle: Text(
                        formatScheduleLabel(choice.at),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing: const Icon(Icons.edit_outlined, size: 20),
                      onTap: pickDateTime,
                    ),
                    const Divider(height: 1),
                  ],
                  for (final option in _quickOptions(now))
                    ListTile(
                      leading: const Icon(Icons.schedule_outlined),
                      title: Text(option.label),
                      trailing: Text(
                        PersianUtils.toPersianNumber(
                          DateFormatter.formatTime(option.at),
                        ),
                        style: theme.textTheme.bodyMedium,
                      ),
                      onTap: () => Navigator.pop(
                        sheetCtx,
                        choice.copyWith(at: option.at),
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.event_outlined),
                    title: const Text('انتخاب تاریخ و ساعت'),
                    onTap: pickDateTime,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.repeat),
                    title: const Text('تکرار'),
                    subtitle: Text(repeatSummary(choice)),
                    onTap: () async {
                      final updated = await _showRepeatSheet(sheetCtx, choice);
                      if (updated != null) {
                        setSheetState(() => choice = updated);
                      }
                    },
                  ),
                  // Jitter is NOT nested under «تکرار»: spreading a *one-shot*
                  // send over a random window is the main reason the option
                  // exists (a message that must not land on a round minute),
                  // and hiding it behind a repeat rule made it unreachable for
                  // exactly that case.
                  ListTile(
                    leading: const Icon(Icons.shuffle),
                    title: const Text('پراکندگی زمان ارسال'),
                    subtitle: Text(jitterLabel(choice.jitter)),
                    onTap: () async {
                      final picked = await _showJitterSheet(
                        sheetCtx,
                        choice.jitter,
                      );
                      if (picked != null) {
                        setSheetState(
                          () => choice = choice.copyWith(jitter: picked),
                        );
                      }
                    },
                  ),
                  if (choice.repeat != ScheduleRepeat.none)
                    ListTile(
                      leading: const Icon(Icons.event_busy_outlined),
                      title: const Text('پایان تکرار'),
                      subtitle: Text(endSummary(choice)),
                      onTap: () async {
                        final updated = await _showEndSheet(sheetCtx, choice);
                        if (updated != null) {
                          setSheetState(() => choice = updated);
                        }
                      },
                    ),
                  if (hasTime)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: FilledButton(
                        onPressed: () => Navigator.pop(sheetCtx, choice),
                        child: const Text('تأیید'),
                      ),
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

/// The pickers open on today at the current time, so «انتخاب تاریخ و ساعت»
/// starts from where the user is rather than from a guessed slot.
DateTime _defaultTime(DateTime now) => now;

List<_QuickOption> _quickOptions(DateTime now) {
  final options = <_QuickOption>[];
  // "Later today" only while 18:00 is still comfortably ahead.
  final laterToday = DateTime(now.year, now.month, now.day, 18);
  if (laterToday.isAfter(now.add(const Duration(minutes: 15)))) {
    options.add(_QuickOption('امروز عصر', laterToday));
  }
  final tomorrow = now.add(const Duration(days: 1));
  options
    ..add(
      _QuickOption(
        'فردا صبح',
        DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 8),
      ),
    )
    ..add(
      _QuickOption(
        'فردا عصر',
        DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 18),
      ),
    );
  return options;
}

/// Date then time, the order Google asks for them. Null if either is dismissed.
Future<DateTime?> _pickDateTime(BuildContext context, DateTime initial) async {
  final now = DateTime.now();
  final date = await showAppDatePicker(
    context: context,
    initialDate: initial.isBefore(now) ? now : initial,
    firstDate: now,
    lastDate: now.add(const Duration(days: 365 * 3)),
  );
  if (date == null || !context.mounted) return null;

  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null) return null;

  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

// ── Repeat / jitter / end pickers ────────────────────────────────────────────

Future<ScheduleChoice?> _showRepeatSheet(
  BuildContext context,
  ScheduleChoice choice,
) {
  var draft = choice;
  return showModalBottomSheet<ScheduleChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                  child: Text(
                    'تکرار',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                RadioGroup<ScheduleRepeat>(
                  groupValue: draft.repeat,
                  onChanged: (v) => setSheetState(
                    () => draft = draft.copyWith(
                      repeat: v,
                      // A one-shot carries no repeat detail.
                      weekdays: v == ScheduleRepeat.none ? <int>{} : null,
                      endType: v == ScheduleRepeat.none
                          ? ScheduleEnd.never
                          : null,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final r in ScheduleRepeat.values)
                        RadioListTile<ScheduleRepeat>(
                          value: r,
                          title: Text(repeatName(r)),
                        ),
                    ],
                  ),
                ),
                if (draft.repeat != ScheduleRepeat.none)
                  ListTile(
                    title: Text('هر چند ${_repeatUnit(draft.repeat)} یک‌بار'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove),
                          onPressed: draft.repeatEvery > 1
                              ? () => setSheetState(
                                  () => draft = draft.copyWith(
                                    repeatEvery: draft.repeatEvery - 1,
                                  ),
                                )
                              : null,
                        ),
                        Text(
                          PersianUtils.toPersianNumber('${draft.repeatEvery}'),
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: draft.repeatEvery < 30
                              ? () => setSheetState(
                                  () => draft = draft.copyWith(
                                    repeatEvery: draft.repeatEvery + 1,
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                if (draft.repeat == ScheduleRepeat.weekly)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (var day = 1; day <= 7; day++)
                          FilterChip(
                            label: Text(_weekdayName(day)),
                            selected: draft.weekdays.contains(day),
                            onSelected: (on) {
                              final next = {...draft.weekdays};
                              if (on) {
                                next.add(day);
                              } else {
                                next.remove(day);
                              }
                              setSheetState(
                                () => draft = draft.copyWith(weekdays: next),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, draft),
                    child: const Text('تأیید'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<JitterWindow?> _showJitterSheet(
  BuildContext context,
  JitterWindow current,
) {
  return showModalBottomSheet<JitterWindow>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Text(
                  'پراکندگی زمان ارسال',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'پیام در بازه‌ای تصادفی پس از زمان تعیین‌شده ارسال می‌شود.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
              RadioGroup<JitterWindow>(
                groupValue: current,
                onChanged: (v) => Navigator.pop(ctx, v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final j in JitterWindow.values)
                      RadioListTile<JitterWindow>(
                        value: j,
                        title: Text(jitterLabel(j)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<ScheduleChoice?> _showEndSheet(
  BuildContext context,
  ScheduleChoice choice,
) {
  var draft = choice;
  return showModalBottomSheet<ScheduleChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                  child: Text(
                    'پایان تکرار',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                RadioGroup<ScheduleEnd>(
                  groupValue: draft.endType,
                  onChanged: (v) async {
                    switch (v) {
                      case null:
                      case ScheduleEnd.never:
                        setSheetState(
                          () => draft = draft.copyWith(
                            endType: ScheduleEnd.never,
                            clearEndDate: true,
                            clearMaxOccurrences: true,
                          ),
                        );
                      case ScheduleEnd.onDate:
                        // Picking the date IS choosing this option; backing out
                        // of the picker leaves the previous choice alone.
                        final picked = await showAppDatePicker(
                          context: ctx,
                          initialDate:
                              draft.endDate ??
                              draft.at.add(const Duration(days: 30)),
                          firstDate: draft.at,
                          lastDate: draft.at.add(const Duration(days: 365 * 3)),
                        );
                        if (picked == null) return;
                        setSheetState(
                          () => draft = draft.copyWith(
                            endType: ScheduleEnd.onDate,
                            endDate: picked,
                            clearMaxOccurrences: true,
                          ),
                        );
                      case ScheduleEnd.afterCount:
                        setSheetState(
                          () => draft = draft.copyWith(
                            endType: ScheduleEnd.afterCount,
                            maxOccurrences: draft.maxOccurrences ?? 5,
                            clearEndDate: true,
                          ),
                        );
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const RadioListTile<ScheduleEnd>(
                        value: ScheduleEnd.never,
                        title: Text('هرگز'),
                      ),
                      RadioListTile<ScheduleEnd>(
                        value: ScheduleEnd.onDate,
                        title: const Text('در تاریخ'),
                        subtitle: draft.endDate == null
                            ? null
                            : Text(
                                PersianUtils.toPersianNumber(
                                  DateFormatter.formatDate(draft.endDate!),
                                ),
                              ),
                      ),
                      RadioListTile<ScheduleEnd>(
                        value: ScheduleEnd.afterCount,
                        title: const Text('پس از چند بار'),
                        subtitle: draft.maxOccurrences == null
                            ? null
                            : Text(
                                PersianUtils.toPersianNumber(
                                  '${draft.maxOccurrences} بار',
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                if (draft.endType == ScheduleEnd.afterCount)
                  ListTile(
                    title: const Text('تعداد تکرار'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove),
                          onPressed: (draft.maxOccurrences ?? 5) > 2
                              ? () => setSheetState(
                                  () => draft = draft.copyWith(
                                    maxOccurrences:
                                        (draft.maxOccurrences ?? 5) - 1,
                                  ),
                                )
                              : null,
                        ),
                        Text(
                          PersianUtils.toPersianNumber(
                            '${draft.maxOccurrences ?? 5}',
                          ),
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () => setSheetState(
                            () => draft = draft.copyWith(
                              maxOccurrences: (draft.maxOccurrences ?? 5) + 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, draft),
                    child: const Text('تأیید'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// ── Labels ───────────────────────────────────────────────────────────────────

String repeatName(ScheduleRepeat r) => switch (r) {
  ScheduleRepeat.none => 'یک‌بار',
  ScheduleRepeat.daily => 'روزانه',
  ScheduleRepeat.weekly => 'هفتگی',
  ScheduleRepeat.monthly => 'ماهانه',
};

String _repeatUnit(ScheduleRepeat r) => switch (r) {
  ScheduleRepeat.none => 'بار',
  ScheduleRepeat.daily => 'روز',
  ScheduleRepeat.weekly => 'هفته',
  ScheduleRepeat.monthly => 'ماه',
};

String _weekdayName(int weekday) => switch (weekday) {
  DateTime.saturday => 'ش',
  DateTime.sunday => 'ی',
  DateTime.monday => 'د',
  DateTime.tuesday => 'س',
  DateTime.wednesday => 'چ',
  DateTime.thursday => 'پ',
  _ => 'ج',
};

String jitterLabel(JitterWindow j) => switch (j) {
  JitterWindow.none => 'بدون پراکندگی',
  JitterWindow.tenMin => 'تا ۱۰ دقیقه',
  JitterWindow.thirtyMin => 'تا ۳۰ دقیقه',
  JitterWindow.sixtyMin => 'تا ۶۰ دقیقه',
};

String repeatSummary(ScheduleChoice choice) {
  if (choice.repeat == ScheduleRepeat.none) return 'یک‌بار';
  final every = choice.repeatEvery > 1
      ? '${PersianUtils.toPersianNumber('${choice.repeatEvery}')} '
      : '';
  final base = 'هر $every${_repeatUnit(choice.repeat)}';
  if (choice.repeat == ScheduleRepeat.weekly && choice.weekdays.isNotEmpty) {
    final days = (choice.weekdays.toList()..sort())
        .map(_weekdayName)
        .join('، ');
    return '$base · $days';
  }
  return base;
}

/// What the composer banner prints after the time: the repeat rule and the
/// jitter window, whichever are set. A one-shot with no jitter has nothing to
/// add, so this returns null and the banner shows the time alone.
String? scheduleDetailSummary(ScheduleChoice choice) {
  final parts = <String>[
    if (choice.repeat != ScheduleRepeat.none) repeatSummary(choice),
    if (choice.jitter != JitterWindow.none)
      '${jitterLabel(choice.jitter)} پراکندگی',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String endSummary(ScheduleChoice choice) => switch (choice.endType) {
  ScheduleEnd.never => 'بدون پایان',
  ScheduleEnd.onDate =>
    choice.endDate == null
        ? 'در تاریخ'
        : 'تا ${PersianUtils.toPersianNumber(DateFormatter.formatDate(choice.endDate!))}',
  ScheduleEnd.afterCount =>
    choice.maxOccurrences == null
        ? 'پس از چند بار'
        : 'پس از ${PersianUtils.toPersianNumber('${choice.maxOccurrences}')} بار',
};

class _QuickOption {
  final String label;
  final DateTime at;

  const _QuickOption(this.label, this.at);
}

/// «امروز، ۱۸:۰۰» / «فردا، ۰۸:۰۰» / «۶ مرداد، ۱۸:۰۰» — how a pending schedule
/// reads in the composer banner and in confirmations. Google names the day
/// rather than printing a numeric date.
String formatScheduleLabel(DateTime at) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(at.year, at.month, at.day);
  final days = that.difference(today).inDays;
  final day = switch (days) {
    0 => 'امروز',
    1 => 'فردا',
    _ => DateFormatter.formatChatSeparator(at),
  };
  return '$day، ${PersianUtils.toPersianNumber(DateFormatter.formatTime(at))}';
}
