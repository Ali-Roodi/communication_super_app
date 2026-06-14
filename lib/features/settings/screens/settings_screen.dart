import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/theme_bloc.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/screens/pin_setup_screen.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';
import 'package:communication_super_app/features/settings/screens/blocked_numbers_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'تنظیمات'),
        body: BlocBuilder<SettingsBloc, SettingsState>(
          builder: (context, s) {
            final bloc = context.read<SettingsBloc>();
            return ListView(
              children: [
                // ── Display options ───────────────────────────────
                const _SectionHeader('نمایش'),
                SwitchListTile(
                  title: const Text('نمایش صفحه‌کلید هنگام شروع'),
                  value: s.showDialpadOnStart,
                  onChanged: (v) => bloc
                      .add(SetBoolSetting(BoolSetting.showDialpadOnStart, v)),
                ),
                _ChoiceTile<bool>(
                  title: 'مرتب‌سازی بر اساس',
                  current: s.sortByLastName,
                  options: const {false: 'نام', true: 'نام خانوادگی'},
                  onSelected: (v) =>
                      bloc.add(SetBoolSetting(BoolSetting.sortByLastName, v)),
                ),
                _ChoiceTile<bool>(
                  title: 'قالب نام',
                  current: s.nameFormatLastFirst,
                  options: const {
                    false: 'نام، نام خانوادگی',
                    true: 'نام خانوادگی، نام',
                  },
                  onSelected: (v) => bloc
                      .add(SetBoolSetting(BoolSetting.nameFormatLastFirst, v)),
                ),
                BlocBuilder<ThemeBloc, ThemeState>(
                  builder: (context, t) => _ChoiceTile<AppThemeMode>(
                    title: 'پوسته',
                    current: t.mode,
                    options: const {
                      AppThemeMode.light: 'روشن',
                      AppThemeMode.dark: 'تاریک',
                      AppThemeMode.system: 'پیش‌فرض سیستم',
                    },
                    onSelected: (m) =>
                        context.read<ThemeBloc>().add(SetThemeMode(m)),
                  ),
                ),
                const _Divider(),

                // ── Sounds and vibration ──────────────────────────
                const _SectionHeader('صدا و لرزش'),
                ListTile(
                  title: const Text('آهنگ زنگ تلفن'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _snack(context, 'انتخاب آهنگ زنگ به‌زودی'),
                ),
                SwitchListTile(
                  title: const Text('لرزش هنگام تماس'),
                  value: s.alsoVibrate,
                  onChanged: (v) =>
                      bloc.add(SetBoolSetting(BoolSetting.alsoVibrate, v)),
                ),
                SwitchListTile(
                  title: const Text('صدای صفحه‌کلید'),
                  value: s.keypadTones,
                  onChanged: (v) =>
                      bloc.add(SetBoolSetting(BoolSetting.keypadTones, v)),
                ),
                SwitchListTile(
                  title: const Text('صدای شماره‌گیر'),
                  value: s.dialpadTones,
                  onChanged: (v) =>
                      bloc.add(SetBoolSetting(BoolSetting.dialpadTones, v)),
                ),
                const _Divider(),

                // ── Quick responses ───────────────────────────────
                const _SectionHeader('پاسخ‌های سریع'),
                for (var i = 0; i < s.quickReplies.length; i++)
                  ListTile(
                    leading: const Icon(Icons.message_outlined),
                    title: Text(s.quickReplies[i]),
                    onTap: () => _editQuickReply(context, bloc, i, s.quickReplies[i]),
                  ),
                const _Divider(),

                // ── Accessibility ─────────────────────────────────
                const _SectionHeader('دسترس‌پذیری'),
                _ChoiceTile<TtyMode>(
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
                SwitchListTile(
                  title: const Text('سمعک'),
                  value: s.hearingAids,
                  onChanged: (v) =>
                      bloc.add(SetBoolSetting(BoolSetting.hearingAids, v)),
                ),
                SwitchListTile(
                  title: const Text('کاهش نویز'),
                  value: s.noiseReduction,
                  onChanged: (v) =>
                      bloc.add(SetBoolSetting(BoolSetting.noiseReduction, v)),
                ),
                const _Divider(),

                // ── Caller ID & spam ──────────────────────────────
                const _SectionHeader('شناسه تماس‌گیرنده و هرزتماس'),
                SwitchListTile(
                  title: const Text('نمایش شناسه و هرزتماس'),
                  value: s.callerIdSpam,
                  onChanged: (v) =>
                      bloc.add(SetBoolSetting(BoolSetting.callerIdSpam, v)),
                ),
                SwitchListTile(
                  title: const Text('فیلتر هرزتماس‌ها'),
                  subtitle: const Text('نیازمند فعال بودن شناسه تماس‌گیرنده'),
                  value: s.filterSpam,
                  onChanged: s.callerIdSpam
                      ? (v) => bloc.add(SetBoolSetting(BoolSetting.filterSpam, v))
                      : null,
                ),
                const _Divider(),

                // ── Blocked numbers ───────────────────────────────
                const _SectionHeader('شماره‌های مسدود'),
                ListTile(
                  leading: const Icon(Icons.block),
                  title: const Text('شماره‌های مسدود'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const BlockedNumbersScreen(),
                    ),
                  ),
                ),
                const _Divider(),

                // ── Security (existing) ───────────────────────────
                const _SectionHeader('امنیت'),
                _buildSecurity(context),
                const _Divider(),

                // ── About ─────────────────────────────────────────
                const _SectionHeader('درباره برنامه'),
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('نام برنامه'),
                  trailing: Text('قاسم', style: TextStyle(color: Colors.grey)),
                ),
                const ListTile(
                  leading: Icon(Icons.tag),
                  title: Text('نسخه'),
                  trailing: Text('۱.۰.۰', style: TextStyle(color: Colors.grey)),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('مجوزهای متن‌باز'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'قاسم',
                    applicationVersion: '۱.۰.۰',
                  ),
                ),
                const SizedBox(height: 32),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── Quick reply edit ────────────────────────────────────────────────────

  Future<void> _editQuickReply(
    BuildContext context,
    SettingsBloc bloc,
    int index,
    String current,
  ) async {
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
              child: const Text('لغو'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      bloc.add(UpdateQuickReply(index, result.trim()));
    }
  }

  // ── Security section (PIN / clear auth) ───────────────────────────────────

  Widget _buildSecurity(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      builder: (context, authState) {
        final authType =
            authState is AuthSet ? authState.authType : AuthType.none;
        final hasPin = authType == AuthType.pin;
        return Column(
          children: [
            ListTile(
              leading: Icon(Icons.pin_outlined,
                  color: hasPin ? Theme.of(context).colorScheme.primary : null),
              title: Text(hasPin ? 'تغییر رمز عبور (PIN)' : 'تنظیم رمز عبور (PIN)'),
              subtitle: Text(hasPin ? 'رمز عبور PIN فعال است' : 'بدون رمز عبور'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PinSetupScreen()),
              ),
            ),
            if (authState is AuthAuthenticated || authState is AuthSet)
              ListTile(
                leading: const Icon(Icons.no_encryption_outlined,
                    color: AppColors.danger),
                title: const Text('حذف قفل برنامه',
                    style: TextStyle(color: AppColors.danger)),
                subtitle: const Text('بدون قفل وارد برنامه می‌شوید'),
                onTap: () => _confirmClearAuth(context),
              ),
          ],
        );
      },
    );
  }

  void _confirmClearAuth(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (dialogCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف قفل برنامه'),
          content: const Text(
            'آیا مطمئن هستید؟ بدون رمز یا الگو می‌توانید وارد برنامه شوید.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('حذف قفل'),
            ),
          ],
        ),
      ),
    ).then((confirmed) {
      if (confirmed == true && context.mounted) {
        context.read<AuthBloc>().add(const ClearAuth());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('قفل برنامه حذف شد')),
        );
      }
    });
  }

  void _snack(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

// ── Choice tile (opens a radio dialog) ────────────────────────────────────────

class _ChoiceTile<T> extends StatelessWidget {
  final String title;
  final T current;
  final Map<T, String> options;
  final ValueChanged<T> onSelected;

  const _ChoiceTile({
    required this.title,
    required this.current,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(options[current] ?? ''),
      trailing: const Icon(Icons.chevron_left),
      onTap: () async {
        final selected = await showDialog<T>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: SimpleDialog(
              title: Text(title),
              children: [
                RadioGroup<T>(
                  groupValue: current,
                  onChanged: (v) => Navigator.of(ctx).pop(v),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: options.entries
                        .map((e) => RadioListTile<T>(
                              value: e.key,
                              title: Text(e.value),
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        );
        if (selected != null) onSelected(selected);
      },
    );
  }
}

// ── Section header & divider ──────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, thickness: 0.5, indent: 16, endIndent: 16);
  }
}
