import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/features/call_history/bloc/call_log_bloc.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_event.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_event.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/message_event.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';

/// The default-app grants the app cannot work without.
///
/// [fullScreenIntent] is not a role but belongs in the same flow: without it an
/// incoming call on a locked phone cannot open this app's call screen, so the
/// OEM dialer takes the call over — the dialer role alone is not enough on
/// Android 14+.
///
/// [callNotifications] is the same kind of grant and the worse failure: with
/// notifications off (or the «تماس ورودی» channel muted) the incoming-call card
/// is dropped *and* its full-screen intent never fires, so the phone rings with
/// nothing on screen and no way to answer — and, because this app holds the
/// dialer role, no OEM screen takes over either. It is asked for right after
/// the dialer role, before the full-screen one, because the full-screen grant
/// is worthless while the notification itself is blocked.
enum DefaultRole { sms, dialer, callNotifications, fullScreenIntent }

/// Google Messages / Google Phone style onboarding for the two default-app
/// roles, shown between [PermissionGate] and the app itself.
///
/// Unlike the old one-shot system dialogs, this screen never fires a role
/// request on its own — the system sheet only opens when the user taps the
/// button. That is what makes re-asking safe: Android permanently auto-denies a
/// role after two refusals of the *system* sheet, so the nagging has to live in
/// our own UI.
///
/// It re-checks on every resume, so setting another app as default elsewhere
/// and coming back lands straight on the request screen again. Dismissing with
/// «فعلاً نه» only lasts until the next resume.
///
/// The moment both roles are held, the device data the app could not see while
/// it was not the default (SMS mirror-sync, call log, contacts) is pulled in.
class DefaultAppGate extends StatefulWidget {
  final Widget child;

  const DefaultAppGate({super.key, required this.child});

  @override
  State<DefaultAppGate> createState() => _DefaultAppGateState();
}

class _DefaultAppGateState extends State<DefaultAppGate>
    with WidgetsBindingObserver {
  /// Null while the first check runs — the app underneath stays hidden so the
  /// screen never flashes in after the UI is already up.
  bool? _isDefaultSms;
  bool? _isDefaultDialer;
  bool? _canFullScreen;
  bool? _callNotifications;

  /// Dismissed for now; cleared on the next resume so returning to the app
  /// asks again.
  bool _skipped = false;

  /// Guards the post-grant sync so it runs once per acquisition, not on every
  /// resume that happens to find the roles held.
  bool _syncedForRoles = false;

  bool _requesting = false;

  /// True once the app itself has been shown. From then on the request page can
  /// no longer be rendered in place — a conversation or contact pushed onto the
  /// root navigator would cover it — so it is pushed as a route instead.
  bool _appShown = false;

  /// The pushed request route, while one is open.
  Route<void>? _openRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _skipped = false;
      _check();
    }
  }

  Future<void> _check() async {
    final sms = await NativeSmsService().isDefaultSmsApp();
    final dialer = await NativeCallService.instance.isDefaultDialer();
    final fullScreen = await NativeCallService.instance.canUseFullScreenIntent();
    final notifications = await NativeCallService.instance
        .areCallNotificationsEnabled();
    if (!mounted) return;

    final hadAll = (_isDefaultSms ?? false) && (_isDefaultDialer ?? false);
    _requesting = false;
    setState(() {
      _isDefaultSms = sms;
      _isDefaultDialer = dialer;
      _canFullScreen = fullScreen;
      _callNotifications = notifications;
    });

    // The roles drive the data sync; the notification and full-screen grants
    // only add a step.
    if (sms && dialer && fullScreen && notifications) {
      // First time we see both roles held in this session: pull everything the
      // app was blind to while another app owned them.
      if (!hadAll || !_syncedForRoles) _syncDeviceData();
      _closeRoute();
    } else {
      _syncedForRoles = false;
      if (_appShown && !_skipped) _openRouteIfNeeded();
    }
  }

  /// Puts the request page on top of whatever screen the user came back to.
  void _openRouteIfNeeded() {
    if (_openRoute != null) return;
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator == null) return;
    final role = _pendingRole;
    if (role == null) return;
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _DefaultRoleScreen(
        role: role,
        onRequest: () => _request(role),
        onSkip: () {
          _skipped = true;
          _closeRoute();
        },
      ),
    );
    _openRoute = route;
    navigator.push(route);
  }

  void _closeRoute() {
    final route = _openRoute;
    if (route == null) return;
    _openRoute = null;
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (route.isActive) navigator?.removeRoute(route);
  }

  /// Re-reads the phone's own stores so the app matches the device after the
  /// role change: the SMS mirror-sync, the call log, and the address book.
  void _syncDeviceData() {
    _syncedForRoles = true;
    try {
      context.read<MessageBloc>().add(const SyncDeviceMessages());
      context.read<CallLogBloc>().add(const SyncCallLogs());
      // RefreshContacts, not LoadContacts: the cache built before the role
      // change would just be served back.
      context.read<ContactBloc>().add(const RefreshContacts());
    } catch (e) {
      debugPrint('DefaultAppGate: post-role sync failed: $e');
    }
  }

  /// The next grant still missing, in the order they are asked for.
  DefaultRole? get _pendingRole {
    if (!(_isDefaultSms ?? false)) return DefaultRole.sms;
    if (!(_isDefaultDialer ?? false)) return DefaultRole.dialer;
    // Before the full-screen grant: that grant only decides whether the card
    // opens the call screen by itself, and a blocked card opens nothing.
    if (!(_callNotifications ?? true)) return DefaultRole.callNotifications;
    if (!(_canFullScreen ?? true)) return DefaultRole.fullScreenIntent;
    return null;
  }

  Future<void> _request(DefaultRole role) async {
    if (_requesting) return;
    _requesting = true;
    try {
      switch (role) {
        case DefaultRole.sms:
          await NativeSmsService().requestDefaultSmsRole();
        case DefaultRole.dialer:
          await NativeCallService.instance.requestDefaultDialerRole();
        case DefaultRole.callNotifications:
          await NativeCallService.instance.openNotificationSettings();
        case DefaultRole.fullScreenIntent:
          // A settings page, not a sheet: the resume re-check picks the result
          // up when the user comes back.
          await NativeCallService.instance.openFullScreenIntentSettings();
      }
    } catch (e) {
      debugPrint('DefaultAppGate: role request failed: $e');
    }
    // Granting a role can restart the process; if it doesn't, the resume
    // callback re-checks. This covers the sheet being dismissed in place.
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (_isDefaultSms == null || _isDefaultDialer == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final role = _pendingRole;
    if (_appShown || _skipped || role == null) {
      _appShown = true;
      return widget.child;
    }

    return _DefaultRoleScreen(
      role: role,
      onRequest: () => _request(role),
      onSkip: () => setState(() => _skipped = true),
    );
  }
}

// ---------------------------------------------------------------------------

/// The request page itself: a tonal icon, a headline, the reasons, and a bottom
/// button bar — the shape Google Messages and Google Phone use for this prompt.
class _DefaultRoleScreen extends StatefulWidget {
  final DefaultRole role;

  /// Opens the system sheet; the page shows a spinner until it returns.
  final Future<void> Function() onRequest;
  final VoidCallback onSkip;

  const _DefaultRoleScreen({
    required this.role,
    required this.onRequest,
    required this.onSkip,
  });

  @override
  State<_DefaultRoleScreen> createState() => _DefaultRoleScreenState();
}

class _DefaultRoleScreenState extends State<_DefaultRoleScreen> {
  bool _busy = false;

  Future<void> _request() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onRequest();
    if (mounted) setState(() => _busy = false);
  }

  /// The two grants that are settings pages rather than a role sheet.
  bool get _opensSettings =>
      widget.role == DefaultRole.fullScreenIntent ||
      widget.role == DefaultRole.callNotifications;

  String get _title => switch (widget.role) {
    DefaultRole.sms => 'هم‌رسان را پیام‌رسان پیش‌فرض کنید',
    DefaultRole.dialer => 'هم‌رسان را برنامه تماس پیش‌فرض کنید',
    DefaultRole.callNotifications => 'اعلان‌های هم‌رسان را روشن کنید',
    DefaultRole.fullScreenIntent => 'اجازه نمایش صفحه تماس را بدهید',
  };

  String get _body => switch (widget.role) {
    DefaultRole.sms =>
      'برای ارسال و دریافت پیامک و همگام ماندن با پیام‌های گوشی، هم‌رسان باید برنامه پیش‌فرض پیامک باشد.',
    DefaultRole.dialer =>
      'برای برقراری تماس و نمایش صفحه تماس ورودی، هم‌رسان باید برنامه پیش‌فرض تماس باشد.',
    DefaultRole.callNotifications =>
      'اعلان‌های هم‌رسان (یا دسته «تماس ورودی») خاموش است. چون هم‌رسان برنامه تماس پیش‌فرض این گوشی است، در این حالت تماس ورودی فقط زنگ می‌خورد و هیچ صفحه‌ای برای پاسخ دادن نمایش داده نمی‌شود. در صفحه‌ای که باز می‌شود، اعلان‌ها و دسته «تماس ورودی» را روشن کنید.',
    DefaultRole.fullScreenIntent =>
      'بدون این اجازه، تماس ورودی روی گوشی قفل صفحه تماس هم‌رسان را باز نمی‌کند و صفحه تماس خود گوشی نشان داده می‌شود. در صفحه‌ای که باز می‌شود، «اعلان تمام‌صفحه» را روشن کنید.',
  };

  IconData get _icon => switch (widget.role) {
    DefaultRole.sms => Icons.chat_bubble_outline_rounded,
    DefaultRole.dialer => Icons.phone_in_talk_outlined,
    DefaultRole.callNotifications => Icons.notifications_off_outlined,
    DefaultRole.fullScreenIntent => Icons.fullscreen_rounded,
  };

  String get _actionLabel =>
      _opensSettings ? 'باز کردن تنظیمات' : 'تنظیم به عنوان پیش‌فرض';

  List<({IconData icon, String text})> get _points => switch (widget.role) {
    DefaultRole.sms => const [
      (icon: Icons.sync_rounded, text: 'همه پیامک‌های گوشی همگام می‌شوند'),
      (
        icon: Icons.notifications_active_outlined,
        text: 'اعلان پیام‌های تازه با پاسخ سریع',
      ),
      (icon: Icons.lock_outline, text: 'پیام‌ها روی همین گوشی می‌مانند'),
    ],
    DefaultRole.dialer => const [
      (icon: Icons.call_outlined, text: 'صفحه تماس ورودی و خروجی هم‌رسان'),
      (icon: Icons.history_rounded, text: 'سابقه تماس‌ها همگام می‌شود'),
      (icon: Icons.block_outlined, text: 'مسدودسازی شماره‌های مزاحم'),
    ],
    DefaultRole.callNotifications => const [
      (icon: Icons.ring_volume_outlined, text: 'دیدن تماس ورودی و پاسخ به آن'),
      (icon: Icons.call_missed_outlined, text: 'اعلان تماس‌های بی‌پاسخ'),
      (icon: Icons.sms_outlined, text: 'اعلان پیامک‌های تازه با پاسخ سریع'),
    ],
    DefaultRole.fullScreenIntent => const [
      (
        icon: Icons.lock_open_rounded,
        text: 'تماس ورودی روی صفحه قفل باز می‌شود',
      ),
      (icon: Icons.touch_app_outlined, text: 'پاسخ و رد تماس با یک لمس'),
      (
        icon: Icons.phonelink_ring_outlined,
        text: 'صفحه تماس هم‌رسان به‌جای صفحه تماس گوشی',
      ),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _icon,
                            size: 44,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        _title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _body,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 32),
                      for (final p in _points)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              Icon(p.icon, size: 22, color: scheme.primary),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  p.text,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : widget.onSkip,
                      child: const Text('فعلاً نه'),
                    ),
                    FilledButton(
                      onPressed: _busy ? null : _request,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 14,
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_actionLabel),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
