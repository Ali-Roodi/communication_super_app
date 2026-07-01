import 'package:intl/intl.dart';
import 'jalali_date.dart';
import 'persian_utils.dart';

/// Formats dates on the **Jalali (Persian) calendar** with Persian digits, so
/// every date/time in the app is shown the way an Iranian user expects.
class DateFormatter {
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

  /// Jalali numeric date, e.g. «۱۴۰۳/۰۴/۱۰».
  static String formatDate(DateTime dateTime) {
    final j = JalaliDate.fromDateTime(dateTime);
    final y = j.year.toString();
    final m = j.month.toString().padLeft(2, '0');
    final d = j.day.toString().padLeft(2, '0');
    return PersianUtils.toPersianNumber('$y/$m/$d');
  }

  /// Jalali date with a spelled-out month + time, e.g. «۱۰ تیر ۱۴:۳۰».
  static String formatDatePersian(DateTime dateTime) {
    final j = JalaliDate.fromDateTime(dateTime);
    final day = PersianUtils.toPersianNumber('${j.day}');
    return '$day ${j.monthName} ${formatTime(dateTime)}';
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
  /// yesterday → «دیروز», within a week → weekday name, older → Jalali date.
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

  /// Jalali "day monthName" for a chat day-separator, appending the year only
  /// when the date is not in the current Jalali year — e.g. «۱۰ تیر» or
  /// «۱۰ تیر ۱۴۰۲».
  static String formatChatSeparator(DateTime dateTime) {
    final j = JalaliDate.fromDateTime(dateTime);
    final nowJ = JalaliDate.fromDateTime(DateTime.now());
    final day = PersianUtils.toPersianNumber('${j.day}');
    if (j.year == nowJ.year) return '$day ${j.monthName}';
    final year = PersianUtils.toPersianNumber('${j.year}');
    return '$day ${j.monthName} $year';
  }
}
