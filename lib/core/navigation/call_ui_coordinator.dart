import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/dialer/screens/incoming_call_screen.dart';
import 'package:communication_super_app/features/dialer/screens/in_call_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';

/// Global navigator key — lets [CallUiCoordinator] push call screens without a
/// route-local context.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Navigates to IncomingCallScreen / InCallScreen on call-state changes.
///
/// Lives directly under `home` — ABOVE the auth flow — deliberately: while the
/// app holds the default-dialer role, this is the only call UI on the device,
/// and it must appear even when the app cold-starts onto the PIN screen (an
/// incoming call cannot wait for an unlock). Only the call screens are exposed;
/// the rest of the app stays behind the lock, and ending the call drops the
/// user back onto whatever was showing before (PIN screen included).
class CallUiCoordinator extends StatefulWidget {
  final Widget child;

  const CallUiCoordinator({super.key, required this.child});

  /// True while a call is up but its screen has been put away.
  ///
  /// Drives the app-wide «بازگشت به تماس» bar. A [ValueNotifier] rather than a
  /// bloc field: the bar is drawn by `MaterialApp.builder`, above the
  /// navigator, and it is the *navigation* that changed, not the call.
  static final ValueNotifier<bool> minimized = ValueNotifier<bool>(false);

  /// Puts the call screen away without ending the call — the back gesture and
  /// the «کوچک کردن» button. The call keeps running; the shade's «تماس در
  /// جریان» card and the in-app bar are the ways back.
  static void minimize() => _CallUiCoordinatorState._instance?._minimize();

  /// Brings the call screen back: the in-app bar, and the notification tap.
  static void restore() => _CallUiCoordinatorState._instance?._restore();

  @override
  State<CallUiCoordinator> createState() => _CallUiCoordinatorState();
}

class _CallUiCoordinatorState extends State<CallUiCoordinator>
    with WidgetsBindingObserver {
  /// The live coordinator. One exists (it wraps `home`); the statics on
  /// [CallUiCoordinator] go through it so the call screen and the return bar
  /// can reach the navigator without a route-local context.
  static _CallUiCoordinatorState? _instance;

  /// Previous call status — the listener needs the transition (not just the
  /// new value) to decide between push / pushReplacement / no-op.
  CallStatus _lastCallStatus = CallStatus.idle;

  /// The number/name the minimized call was showing, so restoring re-opens the
  /// same screen without waiting for another telecom event.
  String _minimizedPhone = '';
  String? _minimizedName;

  StreamSubscription<void>? _showCallUiSubscription;

  @override
  void initState() {
    super.initState();
    _instance = this;
    WidgetsBinding.instance.addObserver(this);
    // «تماس در جریان» tapped in the shade.
    _showCallUiSubscription = NativeCallService.onShowCallUi.listen(
      (_) => _restore(),
    );
  }

  @override
  void dispose() {
    if (_instance == this) _instance = null;
    _showCallUiSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Tells the native side whether its ongoing-call card is needed.
  ///
  /// Never awaited and never allowed to throw: the card is a convenience, and
  /// a channel that is not up yet must not stop the call screen from opening
  /// or closing.
  void _reportCallScreenVisible(bool visible) {
    unawaited(
      NativeCallService.instance.setCallScreenVisible(visible: visible),
    );
  }

  void _minimize() {
    if (_callRoute == null || _lastCallStatus == CallStatus.idle) return;
    final state = context.read<DialerBloc>().state;
    _minimizedPhone = state.activePhone;
    _minimizedName = state.activeName;
    _dismissCallRoute();
    CallUiCoordinator.minimized.value = true;
    _reportCallScreenVisible(false);
  }

  void _restore() {
    if (!mounted) return;
    final state = context.read<DialerBloc>().state;
    // Nothing to go back to: the call ended while the bar or the notification
    // was still on screen.
    if (state.callStatus == CallStatus.idle) {
      CallUiCoordinator.minimized.value = false;
      return;
    }
    if (_callRoute?.isActive == true) {
      // Already up but buried under a conversation/contact page the user
      // opened during the call.
      _bringCallRouteToTop(context);
    } else {
      final phone = state.activePhone.isNotEmpty
          ? state.activePhone
          : _minimizedPhone;
      _pushCall(
        context,
        state.callStatus == CallStatus.incoming
            ? IncomingCallScreen(phone: phone, contactName: state.activeName)
            : InCallScreen(
                phone: phone,
                contactName: state.activeName ?? _minimizedName,
              ),
      );
    }
    CallUiCoordinator.minimized.value = false;
    _reportCallScreenVisible(true);
  }

  /// Coming back to the app is the moment to check the call screen is not a
  /// ghost: every teardown path is an event, and a missed event leaves the
  /// user staring at a call that ended (timer still ticking). Telecom is asked
  /// directly instead.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    context.read<DialerBloc>().add(const SyncCallState());
  }

  /// The call route currently pushed by this coordinator. Kept so that going
  /// idle removes exactly THIS route — a blind `navigator.pop()` could pop an
  /// unrelated screen (or walk the stack past the root) when the call screen
  /// was never pushed or was already gone.
  Route<void>? _callRoute;

  void _pushCall(BuildContext context, Widget screen, {bool replace = false}) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;
    // No transition: an incoming call arrives while whatever was last on screen
    // is still painted, and a 300 ms slide-up means the user watches the inbox
    // (or the PIN screen) on their lock screen before the call appears.
    final route = PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) =>
          BlocProvider.value(value: context.read<DialerBloc>(), child: screen),
    );
    final previous = _callRoute;
    _callRoute = route;
    if (replace && previous != null && previous.isActive) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
    // The screen is up, so the shade card is redundant and the return bar must
    // go. Both are also re-derived on every push, not only on the first: a
    // second call answered from the shade re-opens the screen too.
    CallUiCoordinator.minimized.value = false;
    _reportCallScreenVisible(true);
  }

  void _dismissCallRoute() {
    final navigator = appNavigatorKey.currentState;
    final route = _callRoute;
    _callRoute = null;
    if (navigator == null || route == null || !route.isActive) return;
    navigator.removeRoute(route);
  }

  /// Pops everything above the in-call route (dialer sheet, contact page …)
  /// so the call screen is visible again — used when a second call starts
  /// from the "افزودن تماس" flow. No-op when the call route isn't in the
  /// stack.
  void _bringCallRouteToTop(BuildContext context) {
    final navigator = appNavigatorKey.currentState;
    final route = _callRoute;
    if (navigator == null) return;
    if (route != null && route.isActive) {
      navigator.popUntil((r) => r == route || r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<DialerBloc, DialerState>(
      listenWhen: (prev, curr) => prev.callStatus != curr.callStatus,
      listener: (context, state) {
        final prev = _lastCallStatus;
        _lastCallStatus = state.callStatus;
        final navigator = appNavigatorKey.currentState;
        if (navigator == null) return;

        switch (state.callStatus) {
          case CallStatus.incoming:
            _pushCall(
              context,
              IncomingCallScreen(
                phone: state.activePhone,
                contactName: state.activeName,
              ),
            );
          case CallStatus.ringing:
          case CallStatus.connecting:
            // Outgoing call dialing — show the in-call UI immediately.
            if (prev != CallStatus.active && prev != CallStatus.onHold) {
              _pushCall(
                context,
                InCallScreen(
                  phone: state.activePhone,
                  contactName: state.activeName,
                ),
              );
            } else {
              // Second call placed while one is up (افزودن تماس): the dialer
              // sheet / contact page is stacked above the call screen — clear
              // it so the user lands back on the in-call UI. `_restore` rather
              // than `_bringCallRouteToTop` alone, because the first call may
              // have been minimized, in which case there is no route to raise
              // and one has to be pushed.
              _restore();
            }
          case CallStatus.active:
            if (prev == CallStatus.incoming) {
              // Answered: swap the incoming screen for the in-call screen.
              _pushCall(
                context,
                InCallScreen(
                  phone: state.activePhone,
                  contactName: state.activeName,
                ),
                replace: true,
              );
            } else if (prev != CallStatus.ringing &&
                prev != CallStatus.connecting &&
                prev != CallStatus.onHold) {
              // Active with no prior UI (e.g. cold start into an ongoing call).
              _pushCall(
                context,
                InCallScreen(
                  phone: state.activePhone,
                  contactName: state.activeName,
                ),
              );
            }
          // ringing/connecting/onHold → InCallScreen is already up.
          case CallStatus.onHold:
            break; // InCallScreen renders the hold state itself.
          case CallStatus.idle:
            // The call is over: the return bar and the shade card must go NOW,
            // not after the 600 ms below — a bar offering to go back to a call
            // that ended is worse than no bar.
            CallUiCoordinator.minimized.value = false;
            _minimizedPhone = '';
            _minimizedName = null;
            _reportCallScreenVisible(false);
            // Held for a beat instead of popping straight away. The native side
            // sends the activity behind the keyguard the moment the call ends,
            // and that transition takes a few hundred ms — popping immediately
            // paints the app's own UI over the lock screen while it runs.
            // Google Phone lingers on the ended call for about as long.
            if (prev != CallStatus.idle) {
              Future<void>.delayed(const Duration(milliseconds: 600), () {
                if (!mounted || _lastCallStatus != CallStatus.idle) return;
                _dismissCallRoute();
              });
            }
        }
      },
      child: widget.child,
    );
  }
}
