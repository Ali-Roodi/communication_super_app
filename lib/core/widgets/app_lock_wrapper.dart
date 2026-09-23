import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/navigation/call_ui_coordinator.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/screens/recovery_code_screen.dart';
import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';

/// «قفل خودکار» — asks for the PIN again when the app comes back after sitting
/// in the background for longer than the user chose
/// ([AuthRepository.relockAfterSeconds]).
///
/// The first unlock of a process is `AuthWrapperScreen`'s job; this only
/// re-locks a session that is already open. It used to be a pass-through, and
/// with the unlocked flag persisted for good, a PIN protected nothing: the app
/// opened straight to the inbox from the background, and after a restart too.
///
/// The lock is a **route** pushed on [appNavigatorKey], not a widget stacked
/// over the navigator: it has to cover whatever screen was open (every one of
/// them is a pushed route) and it has to swallow the back key, which an overlay
/// above the navigator cannot — back would pop the conversation underneath it.
/// Being an ordinary route is also what keeps calls working: `CallUiCoordinator`
/// pushes the call screen *after* it, so a ringing phone is answerable on top
/// of the lock and the lock is still there when the call is over. That is the
/// default-dialer rule `CallUiCoordinator` already follows for the PIN screen.
class AppLockWrapper extends StatefulWidget {
  final Widget child;

  const AppLockWrapper({super.key, required this.child});

  @override
  State<AppLockWrapper> createState() => _AppLockWrapperState();
}

class _AppLockWrapperState extends State<AppLockWrapper>
    with WidgetsBindingObserver {
  final AuthRepository _repository = AuthRepository();

  /// When the app last left the foreground; null while it is in front.
  DateTime? _backgroundedAt;

  /// The lock screen on the navigator, while it is up.
  Route<void>? _lockRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // `inactive` alone is not leaving: a permission dialog, the shade pulled
      // down or the task switcher opened all produce it and come straight back.
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _backgroundedAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (since != null) _maybeLock(DateTime.now().difference(since));
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _maybeLock(Duration away) async {
    if (_lockRoute?.isActive == true) return;
    // Only a session that is open: the first unlock of a process is the PIN
    // screen `AuthWrapperScreen` already shows.
    if (context.read<AuthBloc>().state is! AuthAuthenticated) return;
    // A live call owns the screen. Its UI goes over the lock anyway, but
    // coming back to a call through the shade must not stop at a PIN first.
    if (context.read<DialerBloc>().state.isInCall) return;
    if (await _repository.getAuthType() != AuthType.pin) return;
    final after = await AuthRepository.relockAfterSeconds();
    if (away.inSeconds < after) return;
    if (!mounted) return;
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;

    await _repository.setAuthenticated(false);
    final route = PageRouteBuilder<void>(
      // No transition: the app's content must not slide out from under the
      // lock in view of whoever is holding the phone.
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const RelockScreen(),
    );
    _lockRoute = route;
    await navigator.push(route);
    // Popped — by a correct PIN, or by the recovery flow clearing the stack.
    if (identical(_lockRoute, route)) _lockRoute = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The PIN screen over a session that was already open.
///
/// It checks the PIN against the repository itself rather than through
/// `AuthBloc`: the bloc's states drive `AuthWrapperScreen`, and moving it
/// through `AuthSet` would tear down the whole app underneath — the open
/// conversation, the scroll position, the text being typed.
class RelockScreen extends StatefulWidget {
  const RelockScreen({super.key});

  @override
  State<RelockScreen> createState() => _RelockScreenState();
}

class _RelockScreenState extends State<RelockScreen> {
  final AuthRepository _repository = AuthRepository();
  String _pin = '';
  bool _checking = false;
  bool _wrong = false;

  void _onKey(String digit) {
    if (_checking || _pin.length >= 4) return;
    HapticFeedback.lightImpact();
    setState(() {
      _pin += digit;
      _wrong = false;
    });
    if (_pin.length == 4) _verify();
  }

  void _onDelete() {
    if (_checking || _pin.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _verify() async {
    setState(() => _checking = true);
    final ok = await _repository.validatePin(_pin);
    if (!mounted) return;
    if (ok) {
      await _repository.setAuthenticated(true);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    HapticFeedback.heavyImpact();
    setState(() {
      _pin = '';
      _checking = false;
      _wrong = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      // Back must not reach the screens under the lock.
      canPop: false,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 56,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 24),
                Text(
                  'رمز عبور را وارد کنید',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                // Said on the screen, not in a snack bar: this route sits above
                // every Scaffold of the app, and a message that appears
                // somewhere else is a message nobody reads.
                SizedBox(
                  height: 24,
                  child: _wrong
                      ? Text(
                          'رمز عبور اشتباه است',
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      : null,
                ),
                const SizedBox(height: 24),
                PinDots(filled: _pin.length),
                const SizedBox(height: 48),
                PinKeypad(
                  onKey: _onKey,
                  onDelete: _onDelete,
                  enabled: !_checking,
                ),
                const SizedBox(height: 8),
                const ForgotPinButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
