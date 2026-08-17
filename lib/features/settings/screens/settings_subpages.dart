import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/theme_bloc.dart';
import 'package:communication_super_app/core/utils/message_text_scale.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
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
          // The keypad is a bottom sheet opened from the FAB, so "on start"
          // means "when the app opens" — the only moment there is to pop it.
          title: 'باز کردن صفحه‌کلید هنگام اجرای برنامه',
          summary: 'با باز شدن برنامه، صفحه‌کلید شماره‌گیری نمایش داده شود',
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
        const _Heading('صفحه‌کلید شماره‌گیری'),
        SettingsSwitch(
          title: 'صدای کلیدها',
          summary: 'پخش بوق DTMF هنگام لمس کلیدها',
          value: s.dialpadTones,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.dialpadTones, v)),
        ),
        SettingsSwitch(
          title: 'لرزش کلیدها',
          summary: 'لرزش کوتاه هنگام لمس هر کلید',
          value: s.dialpadHaptics,
          onChanged: (v) =>
              bloc.add(SetBoolSetting(BoolSetting.dialpadHaptics, v)),
        ),
        const Divider(height: 24),
        const _Heading('زنگ تماس'),
        // Not a switch: the ringtone and the vibrate-on-ring behaviour belong
        // to Telecom, which rings for the incoming call — this app never plays
        // it, so a toggle here could only pretend. The row opens the screen
        // that does own it.
        _LinkRow(
          title: 'آهنگ زنگ و لرزش تماس',
          summary: 'در تنظیمات صدای اندروید تعیین می‌شود',
          onTap: NativeCallService.instance.openSoundSettings,
        ),
        _LinkRow(
          title: 'اعلان‌های تماس',
          summary: 'صدا و اولویت کانال‌های «تماس ورودی» و «تماس بی‌پاسخ»',
          onTap: NativeCallService.instance.openNotificationSettings,
        ),
      ],
    );
  }
}

/// A plain sub-page row that leaves the app for a system settings screen.
class _LinkRow extends StatelessWidget {
  final String title;
  final String summary;
  final VoidCallback onTap;

  const _LinkRow({
    required this.title,
    required this.summary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 17, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    summary,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.open_in_new, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
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
        _LinkRow(
          title: 'اعلان‌ها',
          summary: 'صدا، اولویت و کانال‌های اعلان در تنظیمات اندروید',
          onTap: NativeCallService.instance.openNotificationSettings,
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
        const MessageTextScaleRow(),
      ],
    );
  }
}

/// «اندازه متن پیام» — the same value the pinch gesture on a conversation
/// writes, with a live sample so the size is judged by reading it rather than
/// by a number.
///
/// The row exists as well as the gesture because a pinch is not discoverable:
/// somebody who needs bigger text is exactly the person least likely to find a
/// hidden two-finger gesture.
class MessageTextScaleRow extends StatelessWidget {
  const MessageTextScaleRow({super.key});

  @override
  Widget build(BuildContext context) {
    final scale = context.settings.messageTextScale;
    final bloc = context.settingsBloc;
    final scheme = Theme.of(context).colorScheme;
    final steps = MessageTextScale.steps;
    final index = steps.indexOf(MessageTextScale.snap(scale));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'اندازه متن پیام',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                MessageTextScale.label(scale),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'در صفحه گفتگو هم می‌توانید با دو انگشت بزرگ‌نمایی کنید',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          Slider(
            value: (index < 0 ? steps.indexOf(MessageTextScale.normal) : index)
                .toDouble(),
            min: 0,
            max: (steps.length - 1).toDouble(),
            divisions: steps.length - 1,
            label: MessageTextScale.label(scale),
            onChanged: (v) => bloc.add(SetMessageTextScale(steps[v.round()])),
          ),
          // The sample is drawn at the chosen size — the only honest preview.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              'نمونه متن پیام',
              textScaler: TextScaler.linear(scale),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
