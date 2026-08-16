import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/permission_service.dart';
import '../sim/sim_bloc.dart';

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
      // The two default-app roles are NOT requested here. Becoming the default
      // SMS/dialer app restarts the process, so firing a role sheet while the
      // runtime permissions are still being answered re-prompts everything on
      // the cold start. They now belong to DefaultAppGate, which sits directly
      // below this gate and only opens a system sheet when the user taps.
      if (!mounted) return;
      // SubscriptionManager answers nothing until READ_PHONE_STATE is granted,
      // so the roster read fired at startup came back empty on a first launch.
      // Re-read now: the SIM address book and every SIM affordance hang off it.
      context.read<SimBloc>().add(const LoadSims());
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

  void _skipToApp() => setState(() => _phase = _GatePhase.done);

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _GatePhase.checking:
        // Deliberately **blank**, not a spinner. This phase is one batched
        // platform round trip long — a spinner that appears and vanishes
        // inside a few frames reads as "the app loads every time I open it",
        // which is exactly what it was reported as. An empty surface is
        // indistinguishable from the launch splash it replaces.
        return const Scaffold(body: SizedBox.shrink());

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
