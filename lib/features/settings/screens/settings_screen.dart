import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/theme_bloc.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/screens/pin_setup_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'تنظیمات'),
        body: ListView(
          children: [
            // ── Appearance ───────────────────────────────────────
            const _SectionHeader('ظاهر'),
            BlocBuilder<ThemeBloc, ThemeState>(
              builder: (context, state) {
                return SwitchListTile(
                  secondary: Icon(
                    state.isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: const Text('حالت تاریک'),
                  subtitle: Text(state.isDark ? 'در حال حاضر: تاریک' : 'در حال حاضر: روشن'),
                  value: state.isDark,
                  onChanged: (_) =>
                      context.read<ThemeBloc>().add(const ToggleTheme()),
                );
              },
            ),
            const _Divider(),

            // ── Security ─────────────────────────────────────────
            const _SectionHeader('امنیت'),
            BlocBuilder<AuthBloc, AuthState>(
              builder: (context, authState) {
                final authType = authState is AuthSet
                    ? authState.authType
                    : AuthType.none;
                final hasPin = authType == AuthType.pin;
                final hasPattern = authType == AuthType.pattern;

                return Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.pin_outlined,
                        color: hasPin
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(hasPin ? 'تغییر رمز عبور (PIN)' : 'تنظیم رمز عبور (PIN)'),
                      subtitle: Text(hasPin ? 'رمز عبور PIN فعال است' : 'بدون رمز عبور'),
                      trailing: const Icon(Icons.chevron_left),
                      // AuthBloc is global — no BlocProvider.value needed
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PinSetupScreen(),
                        ),
                      ),
                    ),
                    // PHASE-2: Pattern lock setup screen not yet implemented
                    ListTile(
                      leading: Icon(
                        Icons.pattern,
                        color: hasPattern
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).disabledColor,
                      ),
                      title: Text(
                        'قفل الگو',
                        style: TextStyle(
                          color: Theme.of(context).disabledColor,
                        ),
                      ),
                      subtitle: const Text('به‌زودی'),
                      enabled: false,
                    ),
                    if (authState is AuthAuthenticated || authState is AuthSet)
                      ListTile(
                        leading: const Icon(
                          Icons.no_encryption_outlined,
                          color: Colors.red,
                        ),
                        title: const Text(
                          'حذف قفل برنامه',
                          style: TextStyle(color: Colors.red),
                        ),
                        subtitle: const Text('بدون قفل وارد برنامه می‌شوید'),
                        onTap: () => _confirmClearAuth(context),
                      ),
                  ],
                );
              },
            ),
            const _Divider(),

            // ── Notifications ─────────────────────────────────────
            const _SectionHeader('اعلان‌ها'),
            ListTile(
              leading: Icon(
                Icons.notifications_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text('اعلان‌های پیام'),
              subtitle: const Text('نمایش اعلان برای پیام‌های دریافتی'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () {
                // PHASE-2: Navigate to notification settings
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('تنظیمات اعلان در نسخه بعدی'),
                  ),
                );
              },
            ),
            const _Divider(),

            // ── About ─────────────────────────────────────────────
            const _SectionHeader('درباره برنامه'),
            ListTile(
              leading: Icon(
                Icons.info_outline,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text('نام برنامه'),
              trailing: const Text(
                'قاسم',
                style: TextStyle(color: Colors.grey),
              ),
            ),
            const ListTile(
              leading: Icon(Icons.tag),
              title: Text('نسخه'),
              trailing: Text(
                '۱.۰.۰',
                style: TextStyle(color: Colors.grey),
              ),
            ),
            const ListTile(
              leading: Icon(Icons.build_outlined),
              title: Text('نوع نسخه'),
              trailing: Text(
                'MVP',
                style: TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 32),
            Center(
              child: Text(
                'ساخته شده با ❤️ در ایران',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// Shows a confirmation dialog before clearing auth credentials.
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
              style: TextButton.styleFrom(foregroundColor: Colors.red),
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
}

// ── Section header ────────────────────────────────────────────────────────────

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

// ── Thin divider between sections ─────────────────────────────────────────────

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, thickness: 0.5, indent: 16, endIndent: 16);
  }
}
