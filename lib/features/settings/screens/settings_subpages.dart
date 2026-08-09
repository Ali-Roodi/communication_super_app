import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/theme_bloc.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';
import 'package:communication_super_app/features/settings/screens/settings_screen.dart';

/// The settings sub-pages.
///
/// Deliberately *not* card-grouped: Google's own sub-pages (Display options,
/// Sounds and vibration…) drop the cards and put plain rows on the page, with
/// the section headings tinted in the primary colour. Grouping is reserved for
/// the hub.
class _SubPage extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SubPage({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: RtlAppBar(title: title),
        body: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: children,
        ),
      ),
    );
  }
}

/// Tinted heading inside a sub-page.
class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

// ── گزینه‌های نمایش ──────────────────────────────────────────────────────────

class DisplayOptionsPage extends StatelessWidget {
  const DisplayOptionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.settings;
    final bloc = context.settingsBloc;
    return _SubPage(
      title: 'گزینه‌های نمایش',
      children: [
        const _Heading('ظاهر'),
        BlocBuilder<ThemeBloc, ThemeState>(
          builder: (context, t) => SettingsChoice<AppThemeMode>(
            title: 'انتخاب پوسته',
            current: t.mode,
            options: const {
              AppThemeMode.light: 'روشن',
              AppThemeMode.dark: 'تاریک',
              AppThemeMode.system: 'پیش‌فرض سیستم',
            },
            onSelected: (m) => context.themeBloc.add(SetThemeMode(m)),
          ),
        ),
        SettingsChoice<CalendarType>(
          title: 'تقویم',
          current: s.calendarType,
          options: const {
            CalendarType.jalali: 'شمسی (هجری خورشیدی)',
            CalendarType.gregorian: 'میلادی',
          },
          onSelected: (c) => bloc.add(SetCalendarType(c)),
        ),
        const Divider(height: 24),
        const _Heading('مخاطبین'),
        SettingsChoice<bool>(
          title: 'مرتب‌سازی بر اساس',
          current: s.sortByLastName,
          options: const {false: 'نام', true: 'نام خانوادگی'},
          onSelected: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.sortByLastName, v)),
        ),
        SettingsChoice<bool>(
          title: 'قالب نام',
          current: s.nameFormatLastFirst,
          options: const {
            false: 'نام، نام خانوادگی',
            true: 'نام خانوادگی، نام',
          },
          onSelected: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.nameFormatLastFirst, v)),
        ),
        const Divider(height: 24),
        const _Heading('شماره‌گیر'),
        SettingsSwitch(
          title: 'نمایش صفحه‌کلید هنگام شروع',
          summary: 'با باز شدن شماره‌گیر، صفحه‌کلید باز باشد',
          value: s.showDialpadOnStart,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.showDialpadOnStart, v)),
        ),
      ],
    );
  }
}

// ── صدا و لرزش ───────────────────────────────────────────────────────────────

class SoundSettingsPage extends StatelessWidget {
  const SoundSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.settings;
    final bloc = context.settingsBloc;
    return _SubPage(
      title: 'صدا و لرزش',
      children: [
        SettingsSwitch(
          title: 'صدای شماره‌گیر',
          summary: 'پخش بوق DTMF هنگام لمس کلیدها',
          value: s.dialpadTones,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.dialpadTones, v)),
        ),
        SettingsSwitch(
          title: 'صدای صفحه‌کلید',
          value: s.keypadTones,
          onChanged: (v) => bloc.add(SetBoolSetting(BoolSetting.keypadTones, v)),
        ),
        SettingsSwitch(
          title: 'لرزش هنگام تماس',
          summary: 'علاوه بر زنگ، گوشی بلرزد',
          value: s.alsoVibrate,
          onChanged: (v) => bloc.add(SetBoolSetting(BoolSetting.alsoVibrate, v)),
        ),
      ],
    );
  }
}

// ── پیامک‌ها ─────────────────────────────────────────────────────────────────

class MessageSettingsPage extends StatelessWidget {
  const MessageSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.settings;
    final bloc = context.settingsBloc;
    return _SubPage(
      title: 'پیامک‌ها',
      children: [
        InkWell(
          onTap: NativeCallService.instance.openNotificationSettings,
          child: const Padding(
            padding: EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('اعلان‌ها', style: TextStyle(fontSize: 17)),
                SizedBox(height: 4),
                Text(
                  'صدا، اولویت و کانال‌های اعلان در تنظیمات اندروید',
                  style: TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
        ),
        SettingsSwitch(
          title: 'گزارش تحویل',
          summary: 'از اپراتور تأیید تحویل بخواه (تیک دوم زیر پیام)',
          value: s.deliveryReports,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.deliveryReports, v)),
        ),
        SettingsSwitch(
          title: 'پیش‌نمایش خودکار پیوند',
          summary: 'برای پیام‌هایی که لینک دارند، کارت پیش‌نمایش نشان داده شود',
          value: s.linkPreviews,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.linkPreviews, v)),
        ),
        SettingsSwitch(
          title: 'کشیدن برای بایگانی',
          summary:
              'کشیدن گفتگو به یک سو آن را بایگانی و به سوی دیگر خوانده/نخوانده می‌کند',
          value: s.swipeActions,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.swipeActions, v)),
        ),
      ],
    );
  }
}

// ── شناسه تماس‌گیرنده و هرزتماس ──────────────────────────────────────────────

class CallerIdSettingsPage extends StatelessWidget {
  const CallerIdSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.settings;
    final bloc = context.settingsBloc;
    return _SubPage(
      title: 'شناسه تماس‌گیرنده و هرزتماس',
      children: [
        SettingsSwitch(
          title: 'نمایش شناسه و هرزتماس',
          summary: 'شناسایی شماره‌های ناشناس و مشکوک',
          value: s.callerIdSpam,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.callerIdSpam, v)),
        ),
        SettingsSwitch(
          title: 'فیلتر هرزتماس‌ها',
          summary: 'نیازمند فعال بودن شناسه تماس‌گیرنده',
          value: s.filterSpam,
          onChanged: s.callerIdSpam
              ? (v) => bloc.add(SetBoolSetting(BoolSetting.filterSpam, v))
              : null,
        ),
      ],
    );
  }
}

// ── دسترس‌پذیری ──────────────────────────────────────────────────────────────

class AccessibilityPage extends StatelessWidget {
  const AccessibilityPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.settings;
    final bloc = context.settingsBloc;
    return _SubPage(
      title: 'دسترس‌پذیری',
      children: [
        SettingsChoice<TtyMode>(
          title: 'حالت TTY',
          current: s.ttyMode,
          options: const {
            TtyMode.off: 'خاموش',
            TtyMode.full: 'کامل',
            TtyMode.hco: 'HCO',
            TtyMode.vco: 'VCO',
          },
          onSelected: (m) => bloc.add(SetTtyMode(m)),
        ),
        SettingsSwitch(
          title: 'سازگاری با سمعک',
          value: s.hearingAids,
          onChanged: (v) => bloc.add(SetBoolSetting(BoolSetting.hearingAids, v)),
        ),
        SettingsSwitch(
          title: 'کاهش نویز',
          value: s.noiseReduction,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.noiseReduction, v)),
        ),
      ],
    );
  }
}

// ── پاسخ‌های سریع ────────────────────────────────────────────────────────────

class QuickRepliesPage extends StatelessWidget {
  const QuickRepliesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.settings;
    final bloc = context.settingsBloc;
    final scheme = Theme.of(context).colorScheme;
    return _SubPage(
      title: 'پاسخ‌های سریع',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
          child: Text(
            'این پیام‌ها هنگام رد کردن تماس با پیامک پیشنهاد می‌شوند.',
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        for (var i = 0; i < s.quickReplies.length; i++)
          InkWell(
            onTap: () => _edit(context, bloc, i, s.quickReplies[i]),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.quickReplies[i],
                      style: TextStyle(fontSize: 17, color: scheme.onSurface),
                    ),
                  ),
                  Icon(Icons.edit_outlined, size: 20, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    SettingsBloc bloc,
    int index,
    String current,
  ) async {
    // Disposed after the dialog closes; it belongs to this function, not to a
    // State with a `dispose` to hang it on.
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('ویرایش پاسخ سریع'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 2,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result != null && result.trim().isNotEmpty) {
      bloc.add(UpdateQuickReply(index, result.trim()));
    }
  }
}
