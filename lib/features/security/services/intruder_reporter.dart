import 'dart:async';

import 'package:flutter/material.dart';

import 'package:communication_super_app/core/navigation/call_ui_coordinator.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';

import 'security_bridge.dart';

/// Tells the user, at the first right PIN after them, that somebody got the
/// PIN wrong three times in a row (matrix row 32: «گزارش موضوع در اولین ورود
/// موفق»). The photos themselves stay in the secure section.
class IntruderReporter {
  IntruderReporter._();

  static const SecurityBridge _bridge = SecurityBridge();
  static bool _showing = false;

  /// A wrong PIN; [failures] in a row so far.
  static void wrongPin(int failures) => unawaited(_bridge.wrongPin(failures));

  /// A right PIN: the report, once the lock screen is gone.
  static void rightPin() {
    if (_showing) return;
    unawaited(() async {
      final report = await _bridge.intruderReport();
      if (report.events <= 0) return;
      // Let the lock screen pop first, so the dialog lands on the app.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (_showing) return;
      _showing = true;
      await _bridge.clearIntruderReport();
      final context = appNavigatorKey.currentContext;
      if (context == null || !context.mounted) {
        _showing = false;
        return;
      }
      final when = DateFormatter.formatDateAndTime(
        DateTime.fromMillisecondsSinceEpoch(report.lastAt),
      );
      final what = report.events == 1
          ? 'رمز برنامه سه بار پشت‌سرهم اشتباه وارد شد'
          : '${PersianUtils.toPersianNumber('${report.events}')} بار، هر بار سه رمز '
                'اشتباه پشت‌سرهم وارد شد';
      try {
        await showDialog<void>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              icon: const Icon(Icons.no_photography_outlined),
              title: const Text('ورود ناموفق به برنامه'),
              content: Text(
                'از آخرین ورود شما، $what (آخرین بار: $when). اگر عکسی گرفته شده باشد، در '
                'تنظیمات ← امنیت ← «عکس از ورود ناموفق» و داخل بخش امن است.',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('متوجه شدم'),
                ),
              ],
            ),
          ),
        );
      } finally {
        _showing = false;
      }
    }());
  }
}
