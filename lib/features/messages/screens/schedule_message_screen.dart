import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import '../bloc/scheduled_bloc.dart';
import '../bloc/scheduled_event.dart';
import '../models/scheduled_message_model.dart';

/// Compose + schedule an outgoing SMS (date/time, repeat, end condition,
/// send-time jitter). Used both for new schedules and editing an existing one.
class ScheduleMessageScreen extends StatefulWidget {
  final String? phoneNumber;
  final String? contactName;
  final String? initialBody;
  final ScheduledMessage? existing;

  const ScheduleMessageScreen({
    super.key,
    this.phoneNumber,
    this.contactName,
    this.initialBody,
    this.existing,
  });

  @override
  State<ScheduleMessageScreen> createState() => _ScheduleMessageScreenState();
}

class _ScheduleMessageScreenState extends State<ScheduleMessageScreen> {
  late final TextEditingController _phoneController;
  late final TextEditingController _bodyController;
  late final TextEditingController _countController;

  late DateTime _scheduledAt;
  ScheduleRepeat _repeat = ScheduleRepeat.none;
  int _repeatEvery = 1;
  final Set<int> _weekdays = {};
  JitterWindow _jitter = JitterWindow.none;
  ScheduleEnd _endType = ScheduleEnd.never;
  DateTime? _endDate;

  // Persian week order → Dart weekday number (Mon=1 … Sun=7).
  static const _weekdayChips = <(String, int)>[
    ('ش', 6),
    ('ی', 7),
    ('د', 1),
    ('س', 2),
    ('چ', 3),
    ('پ', 4),
    ('ج', 5),
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _phoneController = TextEditingController(
      text: e?.phoneNumber ?? widget.phoneNumber ?? '',
    );
    _bodyController = TextEditingController(
      text: e?.body ?? widget.initialBody ?? '',
    );
    _countController = TextEditingController(
      text: (e?.maxOccurrences ?? 10).toString(),
    );
    _scheduledAt =
        e?.scheduledAt ??
        DateTime.now()
            .add(const Duration(hours: 1))
            .copyWith(second: 0, millisecond: 0, microsecond: 0);
    if (e != null) {
      _repeat = e.repeat;
      _repeatEvery = e.repeatEvery;
      _weekdays.addAll(e.weekdays);
      _jitter = e.jitter;
      _endType = e.endType;
      _endDate = e.endDate;
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _bodyController.dispose();
    _countController.dispose();
    super.dispose();
  }

  bool get _editing => widget.existing != null;
  bool get _recipientLocked => widget.phoneNumber != null && !_editing;

  String _fa(String s) => PersianUtils.toPersianNumber(s);

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _scheduledAt,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (picked == null) return;
    setState(() {
      _scheduledAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _scheduledAt.hour,
        _scheduledAt.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt),
    );
    if (picked == null) return;
    setState(() {
      _scheduledAt = DateTime(
        _scheduledAt.year,
        _scheduledAt.month,
        _scheduledAt.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? _scheduledAt.add(const Duration(days: 30)),
      firstDate: _scheduledAt,
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (picked != null) setState(() => _endDate = picked);
  }

  void _save() {
    final phone = _phoneController.text.trim();
    final body = _bodyController.text.trim();
    if (phone.isEmpty) {
      _toast('شماره گیرنده را وارد کنید');
      return;
    }
    if (body.isEmpty) {
      _toast('متن پیام را وارد کنید');
      return;
    }
    if (_scheduledAt.isBefore(DateTime.now()) && !_editing) {
      _toast('زمان انتخاب‌شده گذشته است');
      return;
    }
    int? maxOccurrences;
    if (_endType == ScheduleEnd.afterCount) {
      maxOccurrences = int.tryParse(_countController.text.trim());
      if (maxOccurrences == null || maxOccurrences < 1) {
        _toast('تعداد دفعات معتبر نیست');
        return;
      }
    }
    context.read<ScheduledMessageBloc>().add(
      SaveScheduled(
        id: widget.existing?.id,
        phoneNumber: phone,
        contactName: widget.contactName ?? widget.existing?.contactName,
        body: body,
        scheduledAt: _scheduledAt,
        repeat: _repeat,
        repeatEvery: _repeatEvery,
        weekdays: _repeat == ScheduleRepeat.weekly ? _weekdays : const {},
        jitter: _jitter,
        endType: _repeat == ScheduleRepeat.none ? ScheduleEnd.never : _endType,
        endDate: _endType == ScheduleEnd.onDate ? _endDate : null,
        maxOccurrences: maxOccurrences,
      ),
    );
    Navigator.of(context).pop();
    _toast(_editing ? 'زمان‌بندی به‌روزرسانی شد' : 'پیام زمان‌بندی شد');
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing ? 'ویرایش زمان‌بندی' : 'زمان‌بندی ارسال'),
          actions: [TextButton(onPressed: _save, child: const Text('ذخیره'))],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _recipientField(),
            const SizedBox(height: 12),
            TextField(
              controller: _bodyController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'متن پیام',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            _whenSection(),
            const SizedBox(height: 20),
            _repeatSection(),
            if (_repeat != ScheduleRepeat.none) ...[
              const SizedBox(height: 20),
              _endSection(),
            ],
            const SizedBox(height: 20),
            _jitterSection(),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.schedule_send_outlined),
              label: Text(
                _editing ? 'به‌روزرسانی زمان‌بندی' : 'زمان‌بندی ارسال',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recipientField() {
    if (_recipientLocked) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.person_outline),
        title: Text(widget.contactName ?? _fa(widget.phoneNumber!)),
        subtitle: widget.contactName != null
            ? Text(_fa(widget.phoneNumber!))
            : null,
      );
    }
    return TextField(
      controller: _phoneController,
      keyboardType: TextInputType.phone,
      decoration: const InputDecoration(
        labelText: 'شماره گیرنده',
        prefixIcon: Icon(Icons.person_outline),
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _whenSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('زمان ارسال'),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                label: Text(_fa(DateFormatter.formatDate(_scheduledAt))),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickTime,
                icon: const Icon(Icons.access_time, size: 18),
                label: Text(_fa(DateFormatter.formatTime(_scheduledAt))),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _repeatSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('تکرار'),
        Wrap(
          spacing: 8,
          children: [
            for (final r in ScheduleRepeat.values)
              ChoiceChip(
                label: Text(_repeatLabel(r)),
                selected: _repeat == r,
                onSelected: (_) => setState(() => _repeat = r),
              ),
          ],
        ),
        if (_repeat != ScheduleRepeat.none) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('هر '),
              _stepper(),
              const SizedBox(width: 8),
              Text(_repeatUnitLabel(_repeat)),
            ],
          ),
        ],
        if (_repeat == ScheduleRepeat.weekly) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            children: [
              for (final (label, day) in _weekdayChips)
                FilterChip(
                  label: Text(label),
                  selected: _weekdays.contains(day),
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _weekdays.add(day);
                    } else {
                      _weekdays.remove(day);
                    }
                  }),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _stepper() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: _repeatEvery > 1
              ? () => setState(() => _repeatEvery--)
              : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text(_fa('$_repeatEvery'), style: const TextStyle(fontSize: 16)),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: _repeatEvery < 99
              ? () => setState(() => _repeatEvery++)
              : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }

  Widget _endSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('پایان تکرار'),
        RadioGroup<ScheduleEnd>(
          groupValue: _endType,
          onChanged: (v) => setState(() => _endType = v ?? ScheduleEnd.never),
          child: Column(
            children: [
              RadioListTile<ScheduleEnd>(
                value: ScheduleEnd.never,
                contentPadding: EdgeInsets.zero,
                title: const Text('بدون پایان'),
              ),
              RadioListTile<ScheduleEnd>(
                value: ScheduleEnd.onDate,
                contentPadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    const Text('تا تاریخ'),
                    const Spacer(),
                    if (_endType == ScheduleEnd.onDate)
                      TextButton(
                        onPressed: _pickEndDate,
                        child: Text(
                          _endDate == null
                              ? 'انتخاب'
                              : _fa(DateFormatter.formatDate(_endDate!)),
                        ),
                      ),
                  ],
                ),
              ),
              RadioListTile<ScheduleEnd>(
                value: ScheduleEnd.afterCount,
                contentPadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    const Text('پس از'),
                    const SizedBox(width: 8),
                    if (_endType == ScheduleEnd.afterCount)
                      SizedBox(
                        width: 56,
                        child: TextField(
                          controller: _countController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(isDense: true),
                        ),
                      ),
                    const SizedBox(width: 8),
                    const Text('بار'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _jitterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('پراکندگی زمان ارسال'),
        Wrap(
          spacing: 8,
          children: [
            for (final j in JitterWindow.values)
              ChoiceChip(
                label: Text(_jitterLabel(j)),
                selected: _jitter == j,
                onSelected: (_) => setState(() => _jitter = j),
              ),
          ],
        ),
      ],
    );
  }

  String _repeatLabel(ScheduleRepeat r) => switch (r) {
    ScheduleRepeat.none => 'بدون تکرار',
    ScheduleRepeat.daily => 'روزانه',
    ScheduleRepeat.weekly => 'هفتگی',
    ScheduleRepeat.monthly => 'ماهانه',
  };

  String _repeatUnitLabel(ScheduleRepeat r) => switch (r) {
    ScheduleRepeat.none => '',
    ScheduleRepeat.daily => 'روز',
    ScheduleRepeat.weekly => 'هفته',
    ScheduleRepeat.monthly => 'ماه',
  };

  String _jitterLabel(JitterWindow j) => switch (j) {
    JitterWindow.none => 'رأس ساعت',
    JitterWindow.tenMin => 'تا ۱۰ دقیقه',
    JitterWindow.thirtyMin => 'تا ۳۰ دقیقه',
    JitterWindow.sixtyMin => 'تا ۶۰ دقیقه',
  };
}
