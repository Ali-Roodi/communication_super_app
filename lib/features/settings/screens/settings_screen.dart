import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/edition/screens/inter_org_activation_screen.dart';
import 'package:communication_super_app/core/theme/theme_bloc.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/screens/pin_setup_screen.dart';
import 'package:communication_super_app/features/authentication/screens/recovery_code_screen.dart';
import 'package:communication_super_app/features/authentication/screens/verify_pin_screen.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/keybank/screens/key_bank_screen.dart';
import 'package:communication_super_app/features/security/screens/device_security_screen.dart';
import 'package:communication_super_app/features/security/screens/intruder_photos_screen.dart';
import 'package:communication_super_app/features/security/services/security_bridge.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:communication_super_app/core/services/crash_reporting.dart';
import 'package:communication_super_app/features/dialer/screens/speed_dial_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';
import 'package:communication_super_app/features/messages/screens/spam_and_blocked_screen.dart';
import 'package:communication_super_app/features/settings/screens/privacy_policy_page.dart';
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
                SettingsRow(
                  icon: Icons.phone_callback_outlined,
                  title: 'تماس مجدد خودکار',
                  onTap: () => _push(context, const AutoRedialPage()),
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
  bool? _canFullScreen;
  bool? _callNotifications;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final answers = await Future.wait<bool>([
      _sms.isDefaultSmsApp(),
      NativeCallService.instance.isDefaultDialer(),
      NativeCallService.instance.canUseFullScreenIntent(),
      NativeCallService.instance.areCallNotificationsEnabled(),
    ]);
    if (mounted) {
      setState(() {
        _isDefaultSms = answers[0];
        _isDefaultDialer = answers[1];
        _canFullScreen = answers[2];
        _callNotifications = answers[3];
      });
    }
  }

  String _summary(bool? value) {
    if (value == null) return '…';
    return value ? 'این برنامه پیش‌فرض است' : 'برنامه دیگری پیش‌فرض است';
  }

  String _grantSummary(bool? value) {
    if (value == null) return '…';
    return value ? 'اجازه داده شده' : 'اجازه داده نشده';
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
        // The two call grants that are settings pages rather than roles. They
        // live here because the onboarding prompt for them stops asking after a
        // few «فعلاً نه»s (see `DefaultAppGate`), and a grant the app needs for
        // a locked-screen call must not become unreachable just because the
        // user silenced the nagging.
        SettingsRow(
          icon: Icons.notifications_active_outlined,
          title: 'اعلان‌های تماس',
          summary: _callNotifications == null
              ? '…'
              : (_callNotifications!
                    ? 'روشن'
                    : 'خاموش — تماس ورودی نمایش داده نمی‌شود'),
          onTap: () async {
            await NativeCallService.instance.openNotificationSettings();
            await _refresh();
          },
        ),
        SettingsRow(
          icon: Icons.fullscreen_rounded,
          title: 'اعلان تمام‌صفحه تماس',
          summary: _grantSummary(_canFullScreen),
          onTap: () async {
            await NativeCallService.instance.openFullScreenIntentSettings();
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
      // An LTR isolate (LRI … PDI): a version is left-to-right content, and in
      // this RTL row the bidi algorithm reordered its pieces — the
      // organization build's «1.0.0-org (2000000127)» came out as
      // «org (2000000127)-1.0.0».
      setState(
        () => _version =
            '\u2066${PersianUtils.toPersianNumber('${info.version} (${info.buildNumber})')}\u2069',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final edition = context.select<EditionBloc, AppEdition>(
      (bloc) => bloc.state.edition,
    );
    return GroupedList(
      children: [
        const SettingsRow(
          icon: Icons.info_outline,
          title: 'نام برنامه',
          summary: 'هم‌رسان',
        ),
        SettingsRow(icon: Icons.tag, title: 'نسخه', summary: _version ?? '…'),
        // Every edition installs as the same package and looks the same, so a
        // support call has no other way to learn which one is on the phone.
        SettingsRow(
          icon: Icons.verified_outlined,
          title: 'نوع نسخه',
          summary: edition.label,
        ),
        // Activation exists only in the commercial build; the organization
        // build is its edition by construction (and compiles this row out).
        if (AppEdition.current == AppEdition.commercial)
          SettingsRow(
            icon: Icons.key_outlined,
            title: 'نسخه بین‌سازمانی',
            summary: edition == AppEdition.interOrganization
                ? 'فعال است'
                : 'فعال‌سازی با کد',
            onTap: () =>
                SettingsScreen._push(context, const InterOrgActivationScreen()),
          ),
        SettingsRow(
          icon: Icons.privacy_tip_outlined,
          // The store-facing policy, kept inside the app so the text a
          // reviewer reads and the text a user reads are the same one.
          title: 'حریم خصوصی و دسترسی‌ها',
          onTap: () => SettingsScreen._push(context, const PrivacyPolicyPage()),
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

  /// «قفل خودکار» — seconds in the background before the PIN is asked again.
  int _relockAfter = AuthRepository.defaultRelockAfterSeconds;

  static const Map<int, String> _relockLabels = {
    0: 'فوراً',
    60: 'پس از ۱ دقیقه',
    300: 'پس از ۵ دقیقه',
    1800: 'پس از ۳۰ دقیقه',
  };

  Future<void> _load() async {
    final type = await _repository.getAuthType();
    final relock = await AuthRepository.relockAfterSeconds();
    if (mounted) {
      setState(() {
        _authType = type;
        _relockAfter = relock;
      });
    }
  }

  Future<void> _pickRelock(BuildContext context) async {
    var pending = _relockAfter;
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('قفل خودکار'),
            contentPadding: const EdgeInsets.only(top: 12),
            content: RadioGroup<int>(
              groupValue: pending,
              onChanged: (v) {
                if (v != null) setLocal(() => pending = v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in AuthRepository.relockChoices)
                    RadioListTile<int>(
                      value: s,
                      title: Text(_relockLabels[s]!),
                    ),
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
    if (selected == null) return;
    await AuthRepository.setRelockAfterSeconds(selected);
    if (mounted) setState(() => _relockAfter = selected);
  }

  Future<void> _openPinSetup(BuildContext context) async {
    // Changing a PIN takes the current one: whoever holds an unlocked phone
    // must not be able to replace it, and the secure section needs the old
    // PIN to re-seal its key under the new one.
    String? currentPin;
    if (_authType == AuthType.pin) {
      currentPin = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const VerifyPinScreen()),
      );
      if (currentPin == null || !context.mounted) return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            PinSetupScreen(fromSettings: true, currentPin: currentPin),
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

  /// Whether a secure section exists — it opens with the app PIN.
  static bool _sectionExists(SecureStatus status) =>
      status == SecureStatus.locked ||
      status == SecureStatus.unlocked ||
      status == SecureStatus.broken;

  void _confirmRemovePin(BuildContext context) {
    if (_sectionExists(context.read<SecureSessionBloc>().state.status)) {
      showDialog<void>(
        context: context,
        builder: (dialogCtx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('حذف رمز عبور'),
            content: const Text(
              'بخش امن با رمز برنامه باز می‌شود؛ تا وقتی وجود دارد، رمز برنامه '
              'حذف نمی‌شود. برای حذف رمز، ابتدا «بخش امن» را از همین صفحه حذف '
              'کنید.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('متوجه شدم'),
              ),
            ],
          ),
        ),
      );
      return;
    }
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
        // Wait for the bloc to finish before re-reading: `_load` right after
        // `add` read the storage before the PIN was cleared, and the rows
        // kept saying «تغییر رمز عبور» until the page was reopened.
        final bloc = context.read<AuthBloc>();
        final done = bloc.stream.firstWhere((s) => s is AuthAuthenticated);
        bloc.add(const DisableAuth());
        await done;
        await _load();
        if (context.mounted && _authType == AuthType.none) {
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
          summary: hasPin
              ? 'قفل برنامه فعال است'
              : 'برنامه بدون قفل باز می‌شود',
          onTap: () => _openPinSetup(context),
        ),
        if (hasPin)
          SettingsRow(
            icon: Icons.lock_clock_outlined,
            title: 'قفل خودکار',
            summary: switch (_relockAfter) {
              0 => 'با هر بار خروج از برنامه',
              60 => '۱ دقیقه پس از خروج از برنامه',
              300 => '۵ دقیقه پس از خروج از برنامه',
              _ => '۳۰ دقیقه پس از خروج از برنامه',
            },
            onTap: () => _pickRelock(context),
          ),
        if (hasPin) const _PinToAnswerCallsRow(),
        if (hasPin)
          SettingsRow(
            icon: Icons.key_outlined,
            title: 'کد بازیابی جدید',
            summary: 'کد قبلی باطل می‌شود و کد تازه یک بار نمایش داده می‌شود',
            onTap: () => _regenerateRecoveryCode(context),
          ),
        const _SecureSectionRow(),
        const _KeyBankRow(),
        const _DeviceSecurityRow(),
        if (hasPin) const _IntruderRow(),
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

/// «رمز برای پاسخ به تماس» — see [BoolSetting.pinToAnswerCalls]. The same row
/// in every edition: the secure section has its own lock, so what this guards
/// is the app lock alone.
class _PinToAnswerCallsRow extends StatelessWidget {
  const _PinToAnswerCallsRow();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsBloc, SettingsState>(
      buildWhen: (a, b) => a.pinToAnswerCalls != b.pinToAnswerCalls,
      builder: (context, state) {
        void set(bool value) => context.read<SettingsBloc>().add(
          SetBoolSetting(BoolSetting.pinToAnswerCalls, value),
        );
        return SettingsRow(
          icon: Icons.phone_locked_outlined,
          title: 'رمز برای پاسخ به تماس',
          summary: state.pinToAnswerCalls
              ? 'وقتی برنامه قفل است، پیش از پاسخ به تماس رمز خواسته می‌شود'
              : 'تماس ورودی بدون وارد کردن رمز پاسخ داده می‌شود',
          onTap: () => set(!state.pinToAnswerCalls),
          trailing: Switch(value: state.pinToAnswerCalls, onChanged: set),
        );
      },
    );
  }
}

/// «بخش امن» — where the secure section stands, and the one place it can be
/// deleted on purpose. Absent in the commercial edition.
class _SecureSectionRow extends StatelessWidget {
  const _SecureSectionRow();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SecureSessionBloc>().state;
    if (state.status == SecureStatus.unavailable) {
      return const SizedBox.shrink();
    }
    final exists = _SecurityGroupState._sectionExists(state.status);
    return SettingsRow(
      icon: Icons.shield_outlined,
      title: 'بخش امن',
      summary: switch (state.status) {
        SecureStatus.needsPin => 'برای استفاده، رمز برنامه را تعیین کنید',
        SecureStatus.pinTooShort =>
          'به رمز ۶ رقمی نیاز دارد؛ رمز برنامه را تغییر دهید',
        SecureStatus.notCreated => 'با اولین باز کردن قفل ساخته می‌شود',
        SecureStatus.locked => 'قفل است · برای حذف لمس کنید',
        SecureStatus.unlocked => 'باز است · برای حذف لمس کنید',
        SecureStatus.broken => 'قابل باز شدن نیست · برای حذف لمس کنید',
        SecureStatus.unavailable => null,
      },
      onTap: exists ? () => _confirmDelete(context) : null,
    );
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

/// «بانک کلید» — the keys encrypted SMS will use. Absent in the commercial
/// edition; opens on a locked section too (the screen asks to unlock).
class _KeyBankRow extends StatelessWidget {
  const _KeyBankRow();

  @override
  Widget build(BuildContext context) {
    final status = context.select<SecureSessionBloc, SecureStatus>(
      (bloc) => bloc.state.status,
    );
    if (status == SecureStatus.unavailable) return const SizedBox.shrink();
    return SettingsRow(
      icon: Icons.key_outlined,
      title: 'بانک کلید',
      summary: 'فایل کلید سازمان، گروه‌های عبارت عبور و شماره‌های من',
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const KeyBankScreen())),
    );
  }
}

/// «کنترل امنیت سامانه» (row 29). Secure editions only.
class _DeviceSecurityRow extends StatelessWidget {
  const _DeviceSecurityRow();

  @override
  Widget build(BuildContext context) {
    final status = context.select<SecureSessionBloc, SecureStatus>(
      (bloc) => bloc.state.status,
    );
    if (status == SecureStatus.unavailable) return const SizedBox.shrink();
    return SettingsRow(
      icon: Icons.health_and_safety_outlined,
      title: 'کنترل امنیت سامانه',
      summary: 'روت، ابزار نفوذ، قفل صفحه، به‌روزرسانی و دسترسی برنامه‌ها',
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const DeviceSecurityScreen())),
    );
  }
}

/// «عکس از ورود ناموفق» (row 32): off by default; the camera permission is
/// asked for when it is turned on. Secure editions with an app PIN only.
class _IntruderRow extends StatefulWidget {
  const _IntruderRow();

  @override
  State<_IntruderRow> createState() => _IntruderRowState();
}

class _IntruderRowState extends State<_IntruderRow> {
  static const _bridge = SecurityBridge();
  bool? _enabled;
  bool _camera = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final s = await _bridge.intruderStatus();
    if (mounted) {
      setState(() {
        _enabled = s.enabled;
        _camera = s.camera;
      });
    }
  }

  Future<void> _set(bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    if (on && !_camera) {
      final granted = (await Permission.camera.request()).isGranted;
      if (!granted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'بدون دسترسی دوربین فقط زمان ورودهای ناموفق ثبت می‌شود',
            ),
          ),
        );
      }
    }
    await _bridge.setIntruderEnabled(on);
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final status = context.select<SecureSessionBloc, SecureStatus>(
      (bloc) => bloc.state.status,
    );
    final enabled = _enabled;
    if (status == SecureStatus.unavailable || enabled == null) {
      return const SizedBox.shrink();
    }
    return SettingsRow(
      icon: Icons.no_photography_outlined,
      title: 'عکس از ورود ناموفق',
      summary: !enabled
          ? 'خاموش · با ۳ رمز اشتباه پشت‌سرهم از هر دو دوربین عکس گرفته شود'
          : _camera
          ? 'روشن · برای دیدن عکس‌ها لمس کنید'
          : 'روشن، بدون دسترسی دوربین · فقط زمان ثبت می‌شود',
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const IntruderPhotosScreen())),
      trailing: Switch(value: enabled, onChanged: _set),
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

  /// Greyed and inert while false — a choice that depends on a switch above
  /// it stays on the page, so the user can see what the switch will unlock.
  final bool enabled;

  const SettingsChoice({
    super.key,
    required this.title,
    required this.current,
    required this.options,
    required this.onSelected,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: enabled ? () => _open(context) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
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
            const SizedBox(height: 4),
            Text(
              options[current] ?? '',
              style: TextStyle(
                fontSize: 14,
                color: enabled
                    ? scheme.onSurfaceVariant
                    : scheme.onSurfaceVariant.withValues(alpha: 0.38),
              ),
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
          summary:
              'فقط محل بروز خطا ارسال می‌شود؛ متن پیام‌ها، شماره‌ها و '
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
