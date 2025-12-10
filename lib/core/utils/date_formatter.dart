import 'package:intl/intl.dart';

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
    return DateFormat('HH:mm').format(dateTime);
  }

  static String formatDate(DateTime dateTime) {
    return DateFormat('yyyy/MM/dd').format(dateTime);
  }

  static String formatDatePersian(DateTime dateTime) {
    // Simple implementation - can be enhanced with Persian calendar
    final day = dateTime.day;
    final month = _getPersianMonth(dateTime.month);
    final time = formatTime(dateTime);
    return '$day $month $time';
  }

  static String _getPersianMonth(int month) {
    const months = [
      'فروردین',
      'اردیبهشت',
      'خرداد',
      'تیر',
      'مرداد',
      'شهریور',
      'مهر',
      'آبان',
      'آذر',
      'دی',
      'بهمن',
      'اسفند',
    ];
    if (month >= 1 && month <= 12) {
      return months[month - 1];
    }
    return '';
  }
}







