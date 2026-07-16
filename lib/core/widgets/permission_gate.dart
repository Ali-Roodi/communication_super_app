import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import '../services/permission_service.dart';

/// Guards [child] behind a runtime-permission check.
///
/// On first launch (or whenever a required permission is missing):
///  1. Shows a Persian-language permission-request screen.
///  2. Requests all required permissions sequentially (one dialog at a time).
///  3. After the user responds (granted or denied), shows [child].
///
/// On subsequent launches (all permissions already granted) it renders [child]
/// directly with zero visible overhead.
///
/// Place this widget in the widget tree between the auth layer and
/// [MainNavigation] so that permission dialogs never overlap with the
/// heavy initial data-import triggered by the main screens.
class PermissionGate extends StatefulWidget {
  final Widget child;

  const PermissionGate({super.key, required this.child});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

enum _GatePhase {
  /// Async check in progress – show a neutral loading indicator.
  checking,

  /// At least one permission is missing – show the request UI.
  needsRequest,

  /// All permissions have been handled – show [child].
  done,
}

class _PermissionGateState extends State<PermissionGate> {
  _GatePhase _phase = _GatePhase.checking;
  bool _isRequesting = false;
  Map<Permission, PermissionStatus> _results = {};

  @override
  void initState() {
    super.initState();
    _checkInitial();
  }

  Future<void> _checkInitial() async {
    try {
      final allGranted = await PermissionService.instance
          .hasAllRequiredPermissions();
      if (allGranted) {
        await _maybeRequestDefaultSmsRole();
        await _maybeRequestDefaultDialerRole();
      }
      if (!mounted) return;
      setState(() {
        _phase = allGranted ? _GatePhase.done : _GatePhase.needsRequest;
      });
    } catch (e) {
      debugPrint('PermissionGate: initial check failed: $e');
      if (mounted) setState(() => _phase = _GatePhase.needsRequest);
    }
  }

  Future<void> _requestAll() async {
    if (_isRequesting) return;
    setState(() => _isRequesting = true);
    try {
      final results = await PermissionService.instance.requestAllPermissions();
      // First entry: right after the runtime permissions, ask the system to
      // make this app the default SMS app (needed for full two-way SMS sync)
      // and then the default phone app (needed for the in-app call UI).
      // One-shot each — a refusal is respected; the inbox banner stays
      // available for SMS.
      await _maybeRequestDefaultSmsRole();
      await _maybeRequestDefaultDialerRole();
      if (!mounted) return;
      setState(() {
        _results = results;
        _phase = _GatePhase.done;
        _isRequesting = false;
      });
    } catch (e) {
      debugPrint('PermissionGate: request failed: $e');
      if (mounted) setState(() => _isRequesting = false);
    }
  }

  /// Shows the system "set default SMS app" dialog exactly once, on the first
  /// entry after install. Never repeats (Android permanently auto-denies a
  /// role after two refusals, so nagging here would burn the second chance —
  /// later requests go through the inbox banner instead).
  Future<void> _maybeRequestDefaultSmsRole() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('default_sms_role_requested_v1') ?? false) return;
      // Flag BEFORE the dialog: even if the app is killed mid-dialog we must
      // not re-ask on next launch.
      await prefs.setBool('default_sms_role_requested_v1', true);
      final native = NativeSmsService();
      if (await native.isDefaultSmsApp()) return;
      await native.requestDefaultSmsRole();
    } catch (e) {
      debugPrint('PermissionGate: default-SMS-role request failed: $e');
    }
  }

  /// Same one-shot pattern for the default-dialer role (ROLE_DIALER). Runs
  /// after the SMS dialog so the two system sheets appear sequentially.
  Future<void> _maybeRequestDefaultDialerRole() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('default_dialer_role_requested_v1') ?? false) return;
      await prefs.setBool('default_dialer_role_requested_v1', true);
      final service = NativeCallService.instance;
      if (await service.isDefaultDialer()) return;
      await service.requestDefaultDialerRole();
    } catch (e) {
      debugPrint('PermissionGate: default-dialer-role request failed: $e');
    }
  }

  void _skipToApp() => setState(() => _phase = _GatePhase.done);

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _GatePhase.checking:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));

      case _GatePhase.done:
        return widget.child;

      case _GatePhase.needsRequest:
        return _PermissionRequestScreen(
          results: _results,
          isRequesting: _isRequesting,
          onRequest: _requestAll,
          onSkip: _skipToApp,
        );
    }
  }
}

// ---------------------------------------------------------------------------

class _PermissionRequestScreen extends StatelessWidget {
  final Map<Permission, PermissionStatus> results;
  final bool isRequesting;
  final VoidCallback onRequest;
  final VoidCallback onSkip;

  const _PermissionRequestScreen({
    required this.results,
    required this.isRequesting,
    required this.onRequest,
    required this.onSkip,
  });

  bool get _hasDeniedPermanently =>
      results.values.any((s) => s.isPermanentlyDenied);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasResults = results.isNotEmpty;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.security_rounded,
                  size: 72,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'دسترسی‌های لازم',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'برای استفاده کامل از برنامه، دسترسی به موارد زیر لازم است:',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                ...PermissionService.requiredPermissions.map(
                  (p) => _PermissionRow(permission: p, status: results[p]),
                ),
                const SizedBox(height: 32),
                if (_hasDeniedPermanently) ...[
                  Text(
                    'برخی دسترسی‌ها به طور دائمی رد شده‌اند. برای فعال‌سازی، به تنظیمات بروید.',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => openAppSettings(),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('باز کردن تنظیمات'),
                  ),
                  const SizedBox(height: 8),
                ] else ...[
                  ElevatedButton(
                    onPressed: isRequesting ? null : onRequest,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: isRequesting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            hasResults ? 'تلاش مجدد' : 'اعطای دسترسی',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  const SizedBox(height: 8),
                ],
                TextButton(
                  onPressed: isRequesting ? null : onSkip,
                  child: Text(
                    'ادامه بدون دسترسی',
                    style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final Permission permission;
  final PermissionStatus? status;

  const _PermissionRow({required this.permission, this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGranted = status?.isGranted ?? false;
    final isDenied = status != null && !isGranted;

    IconData icon;
    if (permission == Permission.sms) {
      icon = Icons.message_outlined;
    } else if (permission == Permission.phone) {
      icon = Icons.phone_outlined;
    } else if (permission == Permission.notification) {
      icon = Icons.notifications_outlined;
    } else {
      icon = Icons.contacts_outlined;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 28, color: theme.colorScheme.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              PermissionService.labelFor(permission),
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (status != null)
            Icon(
              isGranted ? Icons.check_circle : Icons.cancel_outlined,
              color: isGranted ? Colors.green : theme.colorScheme.error,
              size: 22,
            )
          else if (isDenied)
            const Icon(Icons.cancel_outlined, color: Colors.red, size: 22),
        ],
      ),
    );
  }
}
