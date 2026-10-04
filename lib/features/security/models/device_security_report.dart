import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';

/// How much one finding weighs.
enum SecurityLevel {
  /// Fine.
  ok,

  /// Worth knowing; the section is still sound.
  info,

  /// Weakens the protection; should be fixed.
  warn,

  /// The secure section cannot be trusted on this phone as it is.
  risk,
}

class SecurityFinding {
  const SecurityFinding(this.level, this.title, this.detail);
  final SecurityLevel level;
  final String title;
  final String detail;
}

/// «کنترل امنیت سامانه» (matrix row 29): the phone's state as it bears on
/// the secure section, worded for the user. Built from the facts
/// `DeviceSecurity.kt` reports; the weighing is here so it can be tested.
class DeviceSecurityReport {
  DeviceSecurityReport(this.findings, {required this.model, DateTime? now})
    : checkedAt = now ?? DateTime.now();

  final List<SecurityFinding> findings;
  final String model;
  final DateTime checkedAt;

  SecurityLevel get worst => findings
      .map((f) => f.level)
      .fold(SecurityLevel.ok, (a, b) => b.index > a.index ? b : a);

  int count(SecurityLevel level) =>
      findings.where((f) => f.level == level).length;

  static DeviceSecurityReport fromFacts(
    Map<String, Object?> f, {
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    final out = <SecurityFinding>[];
    List<String> list(String key) =>
        (f[key] as List?)?.cast<String>() ?? const [];

    final root = list('rootReasons');
    out.add(
      root.isEmpty
          ? const SecurityFinding(
              SecurityLevel.ok,
              'دسترسی روت',
              'نشانه‌ای از روت شدن گوشی پیدا نشد.',
            )
          : SecurityFinding(
              SecurityLevel.risk,
              'گوشی روت شده است',
              'برنامه‌ای با دسترسی روت می‌تواند حافظه هم‌رسان را بخواند. '
                  'نشانه‌ها: ${root.join('، ')}',
            ),
    );

    final hooks = list('hooks');
    if (hooks.isNotEmpty) {
      out.add(
        SecurityFinding(
          SecurityLevel.risk,
          'ابزار نفوذ در برنامه',
          'ابزاری برای دست‌کاری برنامه‌ها در حال اجرا روی هم‌رسان دیده شد '
              '(${hooks.join('، ')}).',
        ),
      );
    }

    switch (f['signature']) {
      case 'other':
        out.add(
          const SecurityFinding(
            SecurityLevel.risk,
            'امضای برنامه رسمی نیست',
            'این نسخه با کلید امضای رسمی هم‌رسان امضا نشده است؛ ممکن است '
                'تغییر داده شده باشد. فقط از فایل رسمی نصب کنید.',
          ),
        );
      case 'release':
        out.add(
          const SecurityFinding(
            SecurityLevel.ok,
            'امضای برنامه',
            'برنامه با کلید رسمی هم‌رسان امضا شده است.',
          ),
        );
    }

    if (f['debuggable'] == true || f['debugger'] == true) {
      out.add(
        const SecurityFinding(
          SecurityLevel.warn,
          'نسخه آزمایشی',
          'این نسخه برای اشکال‌زدایی ساخته شده است و نباید در کار واقعی '
              'استفاده شود.',
        ),
      );
    }

    if (f['emulator'] == true) {
      out.add(
        const SecurityFinding(
          SecurityLevel.warn,
          'شبیه‌ساز',
          'برنامه روی شبیه‌ساز اجرا می‌شود، نه گوشی واقعی.',
        ),
      );
    }

    out.add(
      f['screenLock'] == true
          ? const SecurityFinding(
              SecurityLevel.ok,
              'قفل صفحه گوشی',
              'گوشی قفل صفحه (رمز، الگو یا اثر انگشت) دارد.',
            )
          : const SecurityFinding(
              SecurityLevel.warn,
              'گوشی قفل صفحه ندارد',
              'بدون قفل صفحه، کلیدهای محافظ اندروید هم ضعیف‌ترند. برای گوشی '
                  'رمز یا الگو بگذارید.',
            ),
    );

    if (f['adb'] == true) {
      out.add(
        const SecurityFinding(
          SecurityLevel.warn,
          'اشکال‌زدایی USB روشن است',
          'با کابل می‌توان به گوشی فرمان داد. در تنظیمات توسعه‌دهنده خاموشش '
              'کنید.',
        ),
      );
    } else if (f['developerOptions'] == true) {
      out.add(
        const SecurityFinding(
          SecurityLevel.info,
          'گزینه‌های توسعه‌دهنده روشن است',
          'اگر لازم نیست، خاموشش کنید.',
        ),
      );
    }

    final readers = list('accessibility');
    if (readers.isNotEmpty) {
      out.add(
        SecurityFinding(
          SecurityLevel.warn,
          'برنامه‌هایی که صفحه را می‌خوانند',
          'این برنامه‌ها دسترسی «دسترس‌پذیری» دارند و متن روی صفحه — حتی '
              'بخش امن — را می‌بینند: ${readers.join('، ')}. اگر به آن‌ها '
              'اعتماد ندارید، دسترسی را بردارید.',
        ),
      );
    }

    final patch = DateTime.tryParse('${f['securityPatch'] ?? ''}');
    if (patch != null) {
      final months = (today.year - patch.year) * 12 + today.month - patch.month;
      final when = DateFormatter.formatDate(patch);
      out.add(
        months > 12
            ? SecurityFinding(
                SecurityLevel.warn,
                'به‌روزرسانی امنیتی قدیمی',
                'آخرین وصله امنیتی اندروید $when است؛ بیش از یک سال گذشته.',
              )
            : SecurityFinding(
                SecurityLevel.ok,
                'به‌روزرسانی امنیتی',
                'آخرین وصله امنیتی اندروید: $when.',
              ),
      );
    }

    final sdk = (f['sdk'] as num?)?.toInt() ?? 0;
    if (sdk > 0 && sdk < 29) {
      out.add(
        SecurityFinding(
          SecurityLevel.warn,
          'نسخه قدیمی اندروید',
          'اندروید ${PersianUtils.toPersianNumber('${f['release']}')} دیگر '
              'به‌روزرسانی امنیتی نمی‌گیرد.',
        ),
      );
    }

    if (f['encrypted'] == false) {
      out.add(
        const SecurityFinding(
          SecurityLevel.warn,
          'حافظه گوشی رمز نشده است',
          'رمزنگاری حافظه گوشی خاموش است.',
        ),
      );
    }

    switch (f['keystore']) {
      case 'strongbox':
        out.add(
          const SecurityFinding(
            SecurityLevel.ok,
            'کلید بخش امن',
            'در تراشه امن جداگانه (StrongBox) نگه داشته می‌شود.',
          ),
        );
      case 'tee':
        out.add(
          const SecurityFinding(
            SecurityLevel.ok,
            'کلید بخش امن',
            'در محیط امن سخت‌افزاری گوشی (TEE) نگه داشته می‌شود.',
          ),
        );
      case 'software':
        out.add(
          const SecurityFinding(
            SecurityLevel.warn,
            'کلید بخش امن نرم‌افزاری است',
            'این گوشی محیط امن سخت‌افزاری برای کلیدها ندارد.',
          ),
        );
    }

    if (f['defaultSms'] != true) {
      out.add(
        const SecurityFinding(
          SecurityLevel.warn,
          'هم‌رسان برنامه پیش‌فرض پیامک نیست',
          'پیامک‌های رمز و پیامک مخاطبین مخفی در برنامه پیامک دیگر هم ثبت '
              'می‌شوند.',
        ),
      );
    }
    if (f['defaultDialer'] != true) {
      out.add(
        const SecurityFinding(
          SecurityLevel.warn,
          'هم‌رسان برنامه پیش‌فرض تماس نیست',
          'تماس مخاطبین مخفی در برنامه تلفن دیگر دیده می‌شود.',
        ),
      );
    }

    out.sort((a, b) => b.level.index.compareTo(a.level.index));
    return DeviceSecurityReport(out, model: '${f['model'] ?? ''}', now: today);
  }
}
