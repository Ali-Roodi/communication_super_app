import 'package:intl/intl.dart';
import 'calendar_type.dart';
import 'jalali_date.dart';
import 'persian_utils.dart';

/// Formats dates with Persian digits on whichever calendar the user picked in
/// Settings — Jalali (default) or Gregorian. Digits and weekday/relative words
/// stay Persian in both modes; only the calendar arithmetic and month names
/// change.
class DateFormatter {
  /// Active calendar. Mirrored from `SettingsBloc` (see `SetCalendarType`);
  /// defaults to Jalali so a formatter call before settings load is correct for
  /// the common case.
  static CalendarType calendar = CalendarType.jalali;

  static bool get _isJalali => calendar == CalendarType.jalali;

  /// Persian transliterations of the Gregorian month names, so a Gregorian date
  /// still reads naturally inside the RTL Persian UI.
  static const List<String> gregorianMonthNames = [
    'ژانویه',
    'فوریه',
    'مارس',
    'آوریل',
    'مه',
    'ژوئن',
    'ژوئیه',
    'اوت',
    'سپتامبر',
    'اکتبر',
    'نوامبر',
    'دسامبر',
  ];

  /// (year, month, day, monthName) of [dateTime] on the active calendar.
  static (int, int, int, String) _parts(DateTime dateTime) {
    if (_isJalali) {
      final j = JalaliDate.fromDateTime(dateTime);
      return (j.year, j.month, j.day, j.monthName);
    }
    return (
      dateTime.year,
      dateTime.month,
      dateTime.day,
      gregorianMonthNames[dateTime.month - 1],
    );
  }

  static String formatDateTime(DateTime dateTime, {bool persian = true}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final date = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (date == today) {
      return 'امروز ${formatTime(dateTime)}';
    } else if (date == yesterday) {
      return 'دیروز ${formatTime(dateTime)}';
    } else {
      return formatDate(dateTime);
    }
  }

  static String formatTime(DateTime dateTime) {
    return PersianUtils.toPersianNumber(DateFormat('HH:mm').format(dateTime));
  }

  /// Numeric date on the active calendar, e.g. «۱۴۰۳/۰۴/۱۰» or «۲۰۲۴/۰۶/۳۰».
  static String formatDate(DateTime dateTime) {
    final (y, m, d, _) = _parts(dateTime);
    final ms = m.toString().padLeft(2, '0');
    final ds = d.toString().padLeft(2, '0');
    return PersianUtils.toPersianNumber('$y/$ms/$ds');
  }

  /// Date with a spelled-out month + time, e.g. «۱۰ تیر ۱۴:۳۰».
  static String formatDatePersian(DateTime dateTime) {
    final (_, _, d, name) = _parts(dateTime);
    final day = PersianUtils.toPersianNumber('$d');
    return '$day $name ${formatTime(dateTime)}';
  }

  static const List<String> _weekdaysFa = [
    'دوشنبه', // Mon (DateTime.monday == 1)
    'سه‌شنبه', // Tue
    'چهارشنبه', // Wed
    'پنجشنبه', // Thu
    'جمعه', // Fri
    'شنبه', // Sat
    'یکشنبه', // Sun
  ];

  /// Compact timestamp for conversation/thread lists: today → time,
  /// yesterday → «دیروز», within a week → weekday name, older → numeric date.
  static String formatRelative(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dateTime.year, dateTime.month, dateTime.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return formatTime(dateTime);
    if (diff == 1) return 'دیروز';
    if (diff < 7) return _weekdaysFa[dateTime.weekday - 1];
    return formatDate(dateTime);
  }

  /// "day monthName" for a chat day-separator, appending the year only when the
  /// date is not in the current year — e.g. «۱۰ تیر» or «۱۰ تیر ۱۴۰۲».
  static String formatChatSeparator(DateTime dateTime) {
    final (y, _, d, name) = _parts(dateTime);
    final (nowY, _, _, _) = _parts(DateTime.now());
    final day = PersianUtils.toPersianNumber('$d');
    if (y == nowY) return '$day $name';
    return '$day $name ${PersianUtils.toPersianNumber('$y')}';
  }

  /// "۱۴۰۳/۰۲/۱۵ · ۱۴:۳۰" — full numeric date + time on the active calendar.
  static String formatDateAndTime(DateTime dateTime) =>
      '${formatDate(dateTime)} · ${formatTime(dateTime)}';
}
