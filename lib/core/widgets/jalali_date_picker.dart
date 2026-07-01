import 'package:flutter/material.dart';
import '../utils/jalali_date.dart';
import '../utils/persian_utils.dart';

/// Shows an RTL Jalali (Persian) date picker and returns the chosen date as a
/// Gregorian [DateTime] (time-of-day copied from [initialDate]), or null if
/// dismissed. Drop-in replacement for `showDatePicker` in this Persian app.
Future<DateTime?> showJalaliDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _JalaliDatePickerDialog(
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    ),
  );
}

class _JalaliDatePickerDialog extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  const _JalaliDatePickerDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<_JalaliDatePickerDialog> createState() =>
      _JalaliDatePickerDialogState();
}

class _JalaliDatePickerDialogState extends State<_JalaliDatePickerDialog> {
  late int _year;
  late int _month;
  late int _day;
  late final int _firstYear;
  late final int _lastYear;

  @override
  void initState() {
    super.initState();
    final j = JalaliDate.fromDateTime(widget.initialDate);
    _year = j.year;
    _month = j.month;
    _day = j.day;
    _firstYear = JalaliDate.fromDateTime(widget.firstDate).year;
    _lastYear = JalaliDate.fromDateTime(widget.lastDate).year;
  }

  void _clampDay() {
    final maxDay = JalaliDate.monthLength(_year, _month);
    if (_day > maxDay) _day = maxDay;
  }

  DateTime get _selected =>
      JalaliDate.toDateTime(_year, _month, _day,
          hour: widget.initialDate.hour, minute: widget.initialDate.minute);

  bool get _inRange {
    final d = DateTime(_selected.year, _selected.month, _selected.day);
    final lo = DateTime(
        widget.firstDate.year, widget.firstDate.month, widget.firstDate.day);
    final hi = DateTime(
        widget.lastDate.year, widget.lastDate.month, widget.lastDate.day);
    return !d.isBefore(lo) && !d.isAfter(hi);
  }

  String _fa(Object v) => PersianUtils.toPersianNumber('$v');

  @override
  Widget build(BuildContext context) {
    final dayCount = JalaliDate.monthLength(_year, _month);

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
                label: (m) => JalaliDate.monthNames[m - 1],
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
