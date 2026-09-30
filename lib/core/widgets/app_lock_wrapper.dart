import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/services/app_handoff.dart';
import 'package:communication_super_app/core/navigation/call_ui_coordinator.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/models/pin_policy.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/repositories/pin_attempt_limiter.dart';
import 'package:communication_super_app/features/authentication/screens/recovery_code_screen.dart';
import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';

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
/// Being an ordinary route is also what keeps calls working: a call screen
/// sits *above* the lock, so a ringing phone is answerable on top of it and the
/// lock is still there when the call is over. That is the default-dialer rule
/// `CallUiCoordinator` already follows for the PIN screen — and the order is
/// kept whichever of the two arrives first (see [AppLock]), unless the user
/// asked for «رمز برای پاسخ به تماس».
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

  /// A trip out that the app started itself (the key-file picker) — see
  /// [AppHandoff].
  final HandoffPause _handoff = HandoffPause();

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
        _handoff.onPaused();
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        final excused = _handoff.onResumed() == HandoffResume.excused;
        if (since != null && !excused) {
          _maybeLock(DateTime.now().difference(since));
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _maybeLock(Duration away) async {
    if (AppLock.isUp) return;
    // Only a session that is open: the first unlock of a process is the PIN
    // screen `AuthWrapperScreen` already shows.
    if (context.read<AuthBloc>().state is! AuthAuthenticated) return;
    // An answered call owns the screen: coming back to it through the shade
    // must not stop at a PIN first. A *ringing* one is not skipped — it is
    // locked under (below), so declining it does not leave the app open.
    if (_answeredCallUp()) return;
    if (await _repository.getAuthType() != AuthType.pin) return;
    final after = await AuthRepository.relockAfterSeconds();
    if (away.inSeconds < after) return;
    final pinToAnswer = await SettingsBloc.readPinToAnswerCalls();
    if (!mounted || _answeredCallUp()) return;
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;

    await _repository.setAuthenticated(false);
    AppLock.push(navigator);
    // The phone rang while the app was away and the full-screen intent is
    // what brought it back: the incoming screen is already up and the lock
    // just landed on top of it. That put a PIN between the user and a
    // ringing phone — the reported «برای پاسخ به تماس باید رمز وارد کرد».
    // Unless they asked for exactly that, the call goes back on top, in the
    // same frame.
    if (!pinToAnswer) CallUiCoordinator.raiseAboveLock();
  }

  /// A call that has been answered — alone, or with a second one ringing over
  /// it (call waiting): either way there is a conversation on the line.
  bool _answeredCallUp() {
    final dialer = context.read<DialerBloc>().state;
    return dialer.isInCall ||
        (dialer.callStatus == CallStatus.incoming && dialer.callCount > 1);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The lock screen as a route on [appNavigatorKey], and where it sits relative
/// to the call screens.
///
/// Two things push onto the same navigator independently — the lock (on
/// resume, from [AppLockWrapper]) and the call screen (on a telecom event,
/// from `CallUiCoordinator`) — and which lands first is a race: a ringing
/// phone brings the app forward, so the resume and the call event arrive
/// together. The order must not depend on it, so each side knows about the
/// other: the lock hands a ringing call back the top ([AppLockWrapper]), the
/// coordinator never pops the lock to raise its screen, and with «رمز برای
/// پاسخ به تماس» on the coordinator asks for the lock over its incoming screen
/// ([coverRingingCall]).
abstract final class AppLock {
  static Route<void>? _route;

  /// Whether the lock screen is on the navigator.
  static bool get isUp => _route?.isActive == true;

  /// Whether [route] is the lock — the one route a call screen must never pop.
  static bool isLockRoute(Route<dynamic> route) => identical(route, _route);

  /// Pushes the lock on top of whatever is showing. A lock already somewhere
  /// lower in the stack is retired: one PIN opens the app, not two.
  static void push(NavigatorState navigator) {
    final route = PageRouteBuilder<void>(
      // No transition: the app's content must not slide out from under the
      // lock in view of whoever is holding the phone.
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const RelockScreen(),
    );
    final previous = _route;
    _route = route;
    navigator.push(route).then((_) {
      // Popped — by a correct PIN, or by the recovery flow clearing the stack.
      if (identical(_route, route)) _route = null;
    });
    if (previous != null && previous.isActive) navigator.removeRoute(previous);
  }

  /// «رمز برای پاسخ به تماس»: puts the lock over the incoming screen that
  /// `CallUiCoordinator` has just pushed, when the user asked for the PIN
  /// before answering and the app is locked — cold-started by the ring onto
  /// its PIN screen, or re-locked.
  ///
  /// [stillRinging] is asked again after the reads: the call may have been
  /// answered (a headset, a car) or gone away meanwhile, and an answered call
  /// is never put behind the PIN.
  static Future<void> coverRingingCall(bool Function() stillRinging) async {
    final repository = AuthRepository();
    try {
      if (!await SettingsBloc.readPinToAnswerCalls()) return;
      if (await repository.getAuthType() != AuthType.pin) return;
      if (await repository.isAuthenticated()) return;
    } catch (e) {
      // Nothing thrown from here may reach the call path; the screen stays
      // answerable, which is also the default.
      debugPrint('AppLock: could not decide on covering the call: $e');
      return;
    }
    final navigator = appNavigatorKey.currentState;
    if (navigator == null || !stillRinging()) return;
    if (_route?.isCurrent == true) return;
    push(navigator);
  }
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

  /// Digits in the stored PIN, read when the screen opens; keys are ignored
  /// until it is known, so a 6-digit PIN is never submitted at 4.
  int? _pinLength;

  @override
  void initState() {
    super.initState();
    _repository.pinLength().then((length) {
      if (mounted) setState(() => _pinLength = length);
    });
  }

  String _pin = '';
  bool _checking = false;

  /// What went wrong with the last attempt — a wrong PIN or a lockout.
  String? _error;

  void _onKey(String digit) {
    final length = _pinLength;
    if (length == null || _checking || _pin.length >= length) return;
    HapticFeedback.lightImpact();
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == length) _verify();
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
      if (!mounted) return;
      // Over a call that cold-started the app («رمز برای پاسخ به تماس») the
      // launch PIN screen is still underneath; one PIN opens both.
      final auth = context.read<AuthBloc>();
      if (auth.state is AuthSet) auth.add(const Authenticate());
      Navigator.of(context).pop();
      return;
    }
    final wait = await _repository.pinRetryAfter();
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _pin = '';
      _checking = false;
      _error = wait == null
          ? 'رمز عبور اشتباه است'
          : PinAttemptLimiter.lockoutMessage(wait);
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
                  child: _error != null
                      ? Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      : null,
                ),
                const SizedBox(height: 24),
                PinDots(
                  length: _pinLength ?? PinPolicy.standardLength,
                  filled: _pin.length,
                ),
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
