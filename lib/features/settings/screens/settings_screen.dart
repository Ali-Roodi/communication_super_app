import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:communication_super_app/core/theme/theme_bloc.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/screens/pin_setup_screen.dart';
import 'package:communication_super_app/features/authentication/screens/recovery_code_screen.dart';
import 'package:communication_super_app/core/services/crash_reporting.dart';
import 'package:communication_super_app/features/dialer/screens/speed_dial_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';
import 'package:communication_super_app/features/messages/screens/spam_and_blocked_screen.dart';
import 'package:communication_super_app/features/settings/screens/settings_subpages.dart';

/// The settings hub, laid out the way Google Phone's is: tinted section labels
/// over grouped cards, one entry per row with a leading icon, and the actual
/// options living on plain sub-pages (see `settings_subpages.dart`).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'تنظیمات'),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            // ── Call assist ────────────────────────────────
            const SectionLabel('کمک‌های تماس'),
            GroupedList(
              children: [
                SettingsRow(
                  icon: Icons.dialpad_outlined,
                  // The gesture lives on the keypad; this is where the
                  // assignments can actually be *seen* and changed.
                  title: 'شماره‌گیری سریع',
                  onTap: () => _push(context, const SpeedDialScreen()),
                ),
              ],
            ),

            // ── General ────────────────────────────────────
            const SectionLabel('عمومی'),
            GroupedList(
              children: [
                SettingsRow(
                  icon: Icons.block,
                  // Same page the inbox's overflow menu opens — there is one
                  // blocked list, not a settings copy and an inbox copy.
                  title: 'هرزنامه و مسدودشده',
                  onTap: () => _push(context, const SpamAndBlockedScreen()),
                ),
                SettingsRow(
                  icon: Icons.list,
                  title: 'گزینه‌های نمایش',
                  onTap: () => _push(context, const DisplayOptionsPage()),
                ),
                SettingsRow(
                  icon: Icons.volume_up_outlined,
                  title: 'صدا و لرزش',
                  onTap: () => _push(context, const SoundSettingsPage()),
                ),
                SettingsRow(
                  icon: Icons.chat_bubble_outline,
                  title: 'پیامک‌ها',
                  onTap: () => _push(context, const MessageSettingsPage()),
                ),
              ],
            ),

            // ── Default apps ───────────────────────────────
            const SectionLabel('برنامه‌های پیش‌فرض'),
            const _DefaultAppsGroup(),

            // ── Security ───────────────────────────────────
            const SectionLabel('امنیت'),
            const _SecurityGroup(),

            // ── Diagnostics ────────────────────────────────
            // Only when a DSN was compiled into this build; a switch that
            // cannot do anything is worse than no switch.
            if (CrashReporting.isAvailable) ...[
              const SectionLabel('تشخیص خطا'),
              const _CrashReportingGroup(),
            ],

            // ── About ──────────────────────────────────────
            const SectionLabel('درباره برنامه'),
            const _AboutGroup(),
          ],
        ),
      ),
    );
  }

  static void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}

// ── Default apps ─────────────────────────────────────────────────────────────

/// Shows whether the app currently holds the SMS / dialer roles and offers the
/// system flow to change them. The state is re-read every time the page is
/// built and after each request, because granting a role restarts the process.
class _DefaultAppsGroup extends StatefulWidget {
  const _DefaultAppsGroup();

  @override
  State<_DefaultAppsGroup> createState() => _DefaultAppsGroupState();
}

class _DefaultAppsGroupState extends State<_DefaultAppsGroup> {
  final NativeSmsService _sms = NativeSmsService();
  bool? _isDefaultSms;
  bool? _isDefaultDialer;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final sms = await _sms.isDefaultSmsApp();
    final dialer = await NativeCallService.instance.isDefaultDialer();
    if (mounted) {
      setState(() {
        _isDefaultSms = sms;
        _isDefaultDialer = dialer;
      });
    }
  }

  String _summary(bool? value) {
    if (value == null) return '…';
    return value ? 'این برنامه پیش‌فرض است' : 'برنامه دیگری پیش‌فرض است';
  }

  @override
  Widget build(BuildContext context) {
    return GroupedList(
      children: [
        SettingsRow(
          icon: Icons.sms_outlined,
          title: 'پیام‌رسان پیش‌فرض',
          summary: _summary(_isDefaultSms),
          onTap: () async {
            if (_isDefaultSms == true) {
              await _sms.openDefaultAppsSettings();
            } else {
              await _sms.requestDefaultSmsRole();
            }
            await _refresh();
          },
        ),
        SettingsRow(
          icon: Icons.dialpad,
          title: 'برنامه تلفن پیش‌فرض',
          summary: _summary(_isDefaultDialer),
          onTap: () async {
            if (_isDefaultDialer == true) {
              await _sms.openDefaultAppsSettings();
            } else {
              await NativeCallService.instance.requestDefaultDialerRole();
            }
            await _refresh();
          },
        ),
      ],
    );
  }
}

// ── About ────────────────────────────────────────────────────────────────────

/// Name + version, the version read off the installed package.
///
/// A hardcoded version string is wrong the moment a release goes out and the
/// one place it matters is a bug report, so it comes from `package_info_plus`
/// (the manifest's own versionName/versionCode) instead.
class _AboutGroup extends StatefulWidget {
  const _AboutGroup();

  @override
  State<_AboutGroup> createState() => _AboutGroupState();
}

class _AboutGroupState extends State<_AboutGroup> {
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(
        () => _version = PersianUtils.toPersianNumber(
          '${info.version} (${info.buildNumber})',
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return GroupedList(
      children: [
        const SettingsRow(
          icon: Icons.info_outline,
          title: 'نام برنامه',
          summary: 'هم‌رسان',
        ),
        SettingsRow(
          icon: Icons.tag,
          title: 'نسخه',
          summary: _version ?? '…',
        ),
      ],
    );
  }
}

// ── Security (optional app lock) ─────────────────────────────────────────────

/// Reads the auth type straight from the repository (the bloc's
/// `AuthAuthenticated` state carries no type, so it can't tell "PIN set"
/// from "skipped") and reloads after every action.
class _SecurityGroup extends StatefulWidget {
  const _SecurityGroup();

  @override
  State<_SecurityGroup> createState() => _SecurityGroupState();
}

class _SecurityGroupState extends State<_SecurityGroup> {
  final AuthRepository _repository = AuthRepository();
  AuthType _authType = AuthType.none;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final type = await _repository.getAuthType();
    if (mounted) setState(() => _authType = type);
  }

  Future<void> _openPinSetup(BuildContext context) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const PinSetupScreen(fromSettings: true),
      ),
    );
    await _load();
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('رمز عبور ذخیره شد')));
    }
  }

  /// Mints a fresh recovery code and shows it once.
  ///
  /// Only reachable from inside an unlocked app, which is the whole security
  /// argument: the code is a way back in for someone who already had the PIN,
  /// not a second credential handed out to whoever is holding the phone.
  Future<void> _regenerateRecoveryCode(BuildContext context) async {
    final code = await _repository.regenerateRecoveryCode();
    if (!context.mounted) return;
    await showRecoveryCode(context, code);
  }

  void _confirmRemovePin(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (dialogCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف رمز عبور'),
          content: const Text(
            'آیا مطمئن هستید؟ بدون رمز وارد برنامه می‌شوید و می‌توانید بعداً '
            'دوباره از همین‌جا رمز تعیین کنید.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogCtx).colorScheme.error,
              ),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('حذف رمز'),
            ),
          ],
        ),
      ),
    ).then((confirmed) async {
      if (confirmed == true && context.mounted) {
        // DisableAuth (NOT ClearAuth): keeps the user inside the app and
        // marks setup skipped so the next launch doesn't re-prompt.
        context.read<AuthBloc>().add(const DisableAuth());
        await _load();
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('رمز عبور حذف شد')));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasPin = _authType == AuthType.pin;
    final scheme = Theme.of(context).colorScheme;
    return GroupedList(
      children: [
        SettingsRow(
          icon: Icons.pin_outlined,
          title: hasPin ? 'تغییر رمز عبور' : 'تنظیم رمز عبور',
          summary: hasPin ? 'قفل برنامه فعال است' : 'برنامه بدون قفل باز می‌شود',
          onTap: () => _openPinSetup(context),
        ),
        if (hasPin)
          SettingsRow(
            icon: Icons.key_outlined,
            title: 'کد بازیابی جدید',
            summary: 'کد قبلی باطل می‌شود و کد تازه یک بار نمایش داده می‌شود',
            onTap: () => _regenerateRecoveryCode(context),
          ),
        if (hasPin)
          SettingsRow(
            icon: Icons.no_encryption_outlined,
            title: 'حذف رمز عبور',
            summary: 'بدون قفل وارد برنامه می‌شوید',
            titleColor: scheme.error,
            onTap: () => _confirmRemovePin(context),
          ),
      ],
    );
  }
}

// ── Shared sub-page building blocks ──────────────────────────────────────────

/// A plain (card-less) switch row — the layout Google uses *inside* a settings
/// sub-page, where rows sit directly on the page instead of on cards.
class SettingsSwitch extends StatelessWidget {
  final String title;
  final String? summary;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SettingsSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.summary,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 20, 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      color: enabled
                          ? scheme.onSurface
                          : scheme.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                  if (summary != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      summary!,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

/// A plain sub-page row that opens a radio dialog and shows the current choice
/// as its summary — Google's «Choose theme / Light» pattern.
class SettingsChoice<T> extends StatelessWidget {
  final String title;
  final T current;
  final Map<T, String> options;
  final ValueChanged<T> onSelected;

  const SettingsChoice({
    super.key,
    required this.title,
    required this.current,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 17, color: scheme.onSurface)),
            const SizedBox(height: 4),
            Text(
              options[current] ?? '',
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    var pending = current;
    final selected = await showDialog<T>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text(title),
            contentPadding: const EdgeInsets.only(top: 12),
            content: RadioGroup<T>(
              groupValue: pending,
              onChanged: (v) {
                if (v != null) setLocal(() => pending = v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in options.entries)
                    RadioListTile<T>(value: e.key, title: Text(e.value)),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('انصراف'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(pending),
                child: const Text('تأیید'),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) onSelected(selected);
  }
}

/// Convenience accessors used by the sub-pages.
extension SettingsContext on BuildContext {
  SettingsBloc get settingsBloc => read<SettingsBloc>();
  SettingsState get settings => watch<SettingsBloc>().state;
  ThemeBloc get themeBloc => read<ThemeBloc>();
}


/// «ارسال گزارش خطا» — opt-in, off by default.
///
/// The copy is explicit about what does *not* travel, because in an SMS app
/// that is the only question worth answering. The switch takes effect on the
/// next launch: the reporter is installed around `runApp`, so flipping it
/// mid-session cannot start or stop it honestly.
class _CrashReportingGroup extends StatefulWidget {
  const _CrashReportingGroup();

  @override
  State<_CrashReportingGroup> createState() => _CrashReportingGroupState();
}

class _CrashReportingGroupState extends State<_CrashReportingGroup> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    CrashReporting.readPreference().then((value) {
      if (mounted) setState(() => _enabled = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return GroupedList(
      children: [
        SettingsSwitch(
          title: 'ارسال گزارش خطا',
          summary: 'فقط محل بروز خطا ارسال می‌شود؛ متن پیام‌ها، شماره‌ها و '
              'نام مخاطبین هرگز از گوشی خارج نمی‌شوند',
          value: enabled ?? false,
          onChanged: enabled == null
              ? null
              : (value) async {
                  setState(() => _enabled = value);
                  await CrashReporting.setPreference(value);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('از اجرای بعدی برنامه اعمال می‌شود'),
                    ),
                  );
                },
        ),
      ],
    );
  }
}
