import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/screens/secure_pin_entry_screen.dart';
import 'package:communication_super_app/features/secure/services/secure_vault_service.dart';
import 'package:communication_super_app/features/secure/widgets/secure_lock_button.dart';

/// تنظیمات ← امنیت ← «بخش امن»: the section's own PIN, its fingerprint, and
/// the one place it can be deleted on purpose. Secure editions only.
///
/// Everything here works on a locked section too — changing the PIN or
/// turning the fingerprint on asks for the section PIN, which is the proof
/// that matters; the app being unlocked is not.
class SecureSectionSettingsPage extends StatelessWidget {
  const SecureSectionSettingsPage({super.key});

  static const String _sameAsAppPin =
      'رمز بخش امن باید با رمز برنامه فرق داشته باشد';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SecureSessionBloc>().state;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'بخش امن'),
        body: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text(
                'بخش امن رمز ۶ رقمی خودش را دارد، جدا از رمز برنامه، و با '
                'خروج از برنامه دوباره قفل می‌شود. این رمز راه بازیابی ندارد: '
                'اگر فراموش شود، تنها راه حذف بخش امن و همهٔ محتوای آن است.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (state.status == SecureStatus.notCreated)
              GroupedList(
                children: [
                  SettingsRow(
                    icon: Icons.add_moderator_outlined,
                    title: 'ساخت بخش امن',
                    summary: 'رمز بخش امن را تعیین کنید',
                    onTap: () => openSecureSection(context),
                  ),
                ],
              )
            else if (state.status == SecureStatus.broken)
              GroupedList(
                children: [
                  SettingsRow(
                    icon: Icons.error_outline,
                    title: 'بخش امن باز نمی‌شود',
                    summary: 'کلید آن روی این گوشی در دسترس نیست',
                  ),
                ],
              )
            else if (state.exists) ...[
              const SectionLabel('باز کردن'),
              GroupedList(
                children: [
                  SettingsRow(
                    icon: Icons.password_outlined,
                    title: 'تغییر رمز بخش امن',
                    summary: 'رمز فعلی، سپس رمز جدید',
                    onTap: state.busy ? null : () => _changePin(context),
                  ),
                  _BiometricRow(state: state),
                ],
              ),
            ],
            if (state.exists) ...[
              const SectionLabel('حذف'),
              GroupedList(
                children: [
                  SettingsRow(
                    icon: Icons.delete_forever_outlined,
                    title: 'حذف همیشگی بخش امن',
                    summary: 'همهٔ محتوای بخش امن پاک می‌شود',
                    titleColor: Theme.of(context).colorScheme.error,
                    onTap: state.busy ? null : () => _confirmDelete(context),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Future<String?> _verify(BuildContext context, String pin) {
    final done = Completer<String?>();
    context.read<SecureSessionBloc>().add(SecureVerifyPinRequested(pin, done));
    return done.future;
  }

  static void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _changePin(BuildContext context) async {
    final bloc = context.read<SecureSessionBloc>();
    final current = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (routeContext) => SecurePinEntryScreen(
          title: 'رمز فعلی بخش امن',
          subtitle: 'برای تغییر، اول رمز فعلی را وارد کنید',
          check: (pin) => _verify(routeContext, pin),
        ),
      ),
    );
    if (current == null || !context.mounted) return;
    final next = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => SecurePinEntryScreen(
          title: 'رمز جدید بخش امن',
          subtitle: 'یک رمز ۶ رقمی، جدا از رمز برنامه',
          confirm: true,
          check: (pin) async {
            if (pin == current) return 'رمز جدید با رمز فعلی یکی است';
            if (await AuthRepository().isAppPin(pin)) return _sameAsAppPin;
            return null;
          },
        ),
      ),
    );
    if (next == null || !context.mounted) return;
    final done = Completer<String?>();
    bloc.add(SecureChangePinRequested(current, next, done));
    final refusal = await done.future;
    if (context.mounted) _say(context, refusal ?? 'رمز بخش امن تغییر کرد');
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف بخش امن؟'),
          content: const Text(
            'همه محتوای بخش امن برای همیشه پاک می‌شود و راهی برای بازگرداندن '
            'آن نیست.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('حذف همیشگی'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && context.mounted) {
      context.read<SecureSessionBloc>().add(const SecureResetRequested());
    }
  }
}

/// «باز کردن با اثر انگشت». Strong biometrics only: on most phones that means
/// the fingerprint — face unlock (Samsung's included) cannot release a
/// Keystore key, and is said so rather than silently ignored.
class _BiometricRow extends StatelessWidget {
  const _BiometricRow({required this.state});

  final SecureSessionState state;

  @override
  Widget build(BuildContext context) {
    final on = state.biometricOn;
    final usable =
        on || state.biometricAvailability == BiometricAvailability.available;
    final String summary = on
        ? 'بخش امن با اثر انگشت هم باز می‌شود'
        : switch (state.biometricAvailability) {
            BiometricAvailability.available =>
              'به‌جای رمز بخش امن، با اثر انگشت',
            BiometricAvailability.noneEnrolled =>
              'ابتدا در تنظیمات گوشی اثر انگشت ثبت کنید؛ تشخیص چهرهٔ این '
                  'گوشی برای بخش امن پذیرفته نیست',
            BiometricAvailability.noDeviceLock =>
              'ابتدا برای خود گوشی قفل صفحه تعیین کنید',
            BiometricAvailability.unavailable =>
              'اثر انگشت گوشی فعلاً در دسترس نیست',
            BiometricAvailability.unsupported =>
              'این گوشی اثر انگشتِ قابل استفاده برای بخش امن ندارد',
          };
    return SettingsRow(
      icon: Icons.fingerprint,
      title: 'باز کردن با اثر انگشت',
      summary: summary,
      enabled: usable,
      onTap: usable && !state.busy ? () => _set(context, !on) : null,
      trailing: Switch(
        value: on,
        onChanged: usable && !state.busy ? (v) => _set(context, v) : null,
      ),
    );
  }

  Future<void> _set(BuildContext context, bool enable) async {
    final bloc = context.read<SecureSessionBloc>();
    String? pin;
    if (enable) {
      pin = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (routeContext) => SecurePinEntryScreen(
            title: 'رمز بخش امن',
            subtitle: 'برای روشن کردن اثر انگشت، رمز بخش امن را وارد کنید',
            check: (pin) =>
                SecureSectionSettingsPage._verify(routeContext, pin),
          ),
        ),
      );
      if (pin == null || !context.mounted) return;
    }
    final done = Completer<String?>();
    bloc.add(SecureBiometricToggleRequested(enable, done, pin: pin));
    final refusal = await done.future;
    if (!context.mounted) return;
    if (refusal == null) {
      SecureSectionSettingsPage._say(
        context,
        enable ? 'اثر انگشت برای بخش امن روشن شد' : 'خاموش شد',
      );
    } else if (refusal.isNotEmpty) {
      SecureSectionSettingsPage._say(context, refusal);
    }
  }
}
