import 'package:flutter/material.dart';
import '../utils/calendar_type.dart';
import '../utils/date_formatter.dart';
import '../utils/jalali_date.dart';
import '../utils/persian_utils.dart';

/// Shows an RTL date picker on the calendar the user selected in Settings
/// (Jalali by default, Gregorian on request) and returns the chosen date as a
/// Gregorian [DateTime] (time-of-day copied from [initialDate]), or null if
/// dismissed. Drop-in replacement for `showDatePicker` in this Persian app.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  CalendarType? calendar,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _AppDatePickerDialog(
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      calendar: calendar ?? DateFormatter.calendar,
    ),
  );
}

class _AppDatePickerDialog extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final CalendarType calendar;

  const _AppDatePickerDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.calendar,
  });

  @override
  State<_AppDatePickerDialog> createState() => _AppDatePickerDialogState();
}

class _AppDatePickerDialogState extends State<_AppDatePickerDialog> {
  late int _year;
  late int _month;
  late int _day;
  late final int _firstYear;
  late final int _lastYear;

  bool get _isJalali => widget.calendar == CalendarType.jalali;

  /// Calendar year of a Gregorian [dt] on the active calendar.
  int _yearOf(DateTime dt) =>
      _isJalali ? JalaliDate.fromDateTime(dt).year : dt.year;

  int _monthLength(int y, int m) {
    if (_isJalali) return JalaliDate.monthLength(y, m);
    // Day 0 of the next month == last day of month m.
    return DateTime(y, m + 1, 0).day;
  }

  List<String> get _monthNames =>
      _isJalali ? JalaliDate.monthNames : DateFormatter.gregorianMonthNames;

  @override
  void initState() {
    super.initState();
    if (_isJalali) {
      final j = JalaliDate.fromDateTime(widget.initialDate);
      _year = j.year;
      _month = j.month;
      _day = j.day;
    } else {
      _year = widget.initialDate.year;
      _month = widget.initialDate.month;
      _day = widget.initialDate.day;
    }
    _firstYear = _yearOf(widget.firstDate);
    _lastYear = _yearOf(widget.lastDate);
  }

  void _clampDay() {
    final maxDay = _monthLength(_year, _month);
    if (_day > maxDay) _day = maxDay;
  }

  DateTime get _selected {
    final h = widget.initialDate.hour;
    final min = widget.initialDate.minute;
    return _isJalali
        ? JalaliDate.toDateTime(_year, _month, _day, hour: h, minute: min)
        : DateTime(_year, _month, _day, h, min);
  }

  bool get _inRange {
    final d = DateTime(_selected.year, _selected.month, _selected.day);
    final lo = DateTime(
      widget.firstDate.year,
      widget.firstDate.month,
      widget.firstDate.day,
    );
    final hi = DateTime(
      widget.lastDate.year,
      widget.lastDate.month,
      widget.lastDate.day,
    );
    return !d.isBefore(lo) && !d.isAfter(hi);
  }

  String _fa(Object v) => PersianUtils.toPersianNumber('$v');

  @override
  Widget build(BuildContext context) {
    final dayCount = _monthLength(_year, _month);
    final monthNames = _monthNames;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('انتخاب تاریخ'),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: _dropdown<int>(
                value: _day,
                items: [for (var d = 1; d <= dayCount; d++) d],
                label: (d) => _fa(d),
                onChanged: (d) => setState(() => _day = d),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: _dropdown<int>(
                value: _month,
                items: [for (var m = 1; m <= 12; m++) m],
                label: (m) => monthNames[m - 1],
                onChanged: (m) => setState(() {
                  _month = m;
                  _clampDay();
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: _dropdown<int>(
                value: _year,
                items: [for (var y = _firstYear; y <= _lastYear; y++) y],
                label: (y) => _fa(y),
                onChanged: (y) => setState(() {
                  _year = y;
                  _clampDay();
                }),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('لغو'),
          ),
          TextButton(
            onPressed: _inRange
                ? () => Navigator.of(context).pop(_selected)
                : null,
            child: const Text('تأیید'),
          ),
        ],
      ),
    );
  }

  Widget _dropdown<T>({
    required T value,
    required List<T> items,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) {
    return DropdownButton<T>(
      value: value,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: [
        for (final it in items)
          DropdownMenuItem(value: it, child: Text(label(it))),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
