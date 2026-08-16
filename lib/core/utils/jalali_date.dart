/// Minimal, dependency-free Gregorian → Jalali (Persian/Shamsi) date
/// conversion. Implements the well-known jdf algorithm.
///
/// The app is a Persian (RTL) app, so every user-facing date is shown on the
/// Jalali calendar. Only the date part is converted — the time is unaffected.
class JalaliDate {
  final int year;
  final int month; // 1..12
  final int day; // 1..31

  const JalaliDate(this.year, this.month, this.day);

  static const List<String> monthNames = [
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

  String get monthName =>
      (month >= 1 && month <= 12) ? monthNames[month - 1] : '';

  static JalaliDate fromDateTime(DateTime dt) =>
      fromGregorian(dt.year, dt.month, dt.day);

  static JalaliDate fromGregorian(int gy, int gm, int gd) {
    const gDaysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    const jDaysInMonth = [31, 31, 31, 31, 31, 31, 30, 30, 30, 30, 30, 29];

    final gy2 = gy - 1600;
    final gm2 = gm - 1;
    final gd2 = gd - 1;

    var gDayNo =
        365 * gy2 +
        ((gy2 + 3) ~/ 4) -
        ((gy2 + 99) ~/ 100) +
        ((gy2 + 399) ~/ 400);
    for (var i = 0; i < gm2; ++i) {
      gDayNo += gDaysInMonth[i];
    }
    // Leap-day for the current Gregorian year.
    if (gm2 > 1 && ((gy % 4 == 0 && gy % 100 != 0) || (gy % 400 == 0))) {
      gDayNo++;
    }
    gDayNo += gd2;

    var jDayNo = gDayNo - 79;
    final jNp = jDayNo ~/ 12053;
    jDayNo %= 12053;

    var jy = 979 + 33 * jNp + 4 * (jDayNo ~/ 1461);
    jDayNo %= 1461;

    if (jDayNo >= 366) {
      jy += (jDayNo - 1) ~/ 365;
      jDayNo = (jDayNo - 1) % 365;
    }

    var jm = 0;
    for (; jm < 11 && jDayNo >= jDaysInMonth[jm]; ++jm) {
      jDayNo -= jDaysInMonth[jm];
    }
    return JalaliDate(jy, jm + 1, jDayNo + 1);
  }

  /// Converts a Jalali date (plus optional time-of-day) back to a Gregorian
  /// [DateTime]. Implements the inverse jdf algorithm.
  static DateTime toDateTime(
    int jy,
    int jm,
    int jd, {
    int hour = 0,
    int minute = 0,
  }) {
    var y = jy + 1595;
    var days =
        -355668 +
        (365 * y) +
        ((y ~/ 33) * 8) +
        (((y % 33) + 3) ~/ 4) +
        jd +
        ((jm < 7) ? (jm - 1) * 31 : ((jm - 7) * 30) + 186);
    var gy = 400 * (days ~/ 146097);
    days %= 146097;
    if (days > 36524) {
      gy += 100 * (--days ~/ 36524);
      days %= 36524;
      if (days >= 365) days++;
    }
    gy += 4 * (days ~/ 1461);
    days %= 1461;
    if (days > 365) {
      gy += (days - 1) ~/ 365;
      days = (days - 1) % 365;
    }
    var gd = days + 1;
    final leap = (gy % 4 == 0 && gy % 100 != 0) || (gy % 400 == 0);
    final monthLengths = [
      0,
      31,
      leap ? 29 : 28,
      31,
      30,
      31,
      30,
      31,
      31,
      30,
      31,
      30,
      31,
    ];
    var gm = 1;
    for (; gm <= 12; gm++) {
      if (gd <= monthLengths[gm]) break;
      gd -= monthLengths[gm];
    }
    return DateTime(gy, gm, gd, hour, minute);
  }

  DateTime toDateTimeWith({int hour = 0, int minute = 0}) =>
      toDateTime(year, month, day, hour: hour, minute: minute);

  /// Number of days in the given Jalali month, derived from the calendar itself
  /// (so leap years are handled without a separate leap rule).
  static int monthLength(int jy, int jm) {
    final start = toDateTime(jy, jm, 1);
    final nextY = jm == 12 ? jy + 1 : jy;
    final nextM = jm == 12 ? 1 : jm + 1;
    return toDateTime(nextY, nextM, 1).difference(start).inDays;
  }
}
