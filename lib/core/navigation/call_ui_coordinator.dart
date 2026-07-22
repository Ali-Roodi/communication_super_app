import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/dialer/screens/incoming_call_screen.dart';
import 'package:communication_super_app/features/dialer/screens/in_call_screen.dart';

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

  @override
  State<CallUiCoordinator> createState() => _CallUiCoordinatorState();
}

class _CallUiCoordinatorState extends State<CallUiCoordinator> {
  /// Previous call status — the listener needs the transition (not just the
  /// new value) to decide between push / pushReplacement / no-op.
  CallStatus _lastCallStatus = CallStatus.idle;

  /// The call route currently pushed by this coordinator. Kept so that going
  /// idle removes exactly THIS route — a blind `navigator.pop()` could pop an
  /// unrelated screen (or walk the stack past the root) when the call screen
  /// was never pushed or was already gone.
  Route<void>? _callRoute;

  void _pushCall(BuildContext context, Widget screen, {bool replace = false}) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          BlocProvider.value(value: context.read<DialerBloc>(), child: screen),
    );
    final previous = _callRoute;
    _callRoute = route;
    if (replace && previous != null && previous.isActive) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
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
            _pushCall(context, IncomingCallScreen(phone: state.activePhone));
          case CallStatus.ringing:
          case CallStatus.connecting:
            // Outgoing call dialing — show the in-call UI immediately.
            if (prev != CallStatus.active && prev != CallStatus.onHold) {
              _pushCall(context, InCallScreen(phone: state.activePhone));
            } else {
              // Second call placed while one is up (افزودن تماس): the dialer
              // sheet / contact page is stacked above the call screen — clear
              // it so the user lands back on the in-call UI.
              _bringCallRouteToTop(context);
            }
          case CallStatus.active:
            if (prev == CallStatus.incoming) {
              // Answered: swap the incoming screen for the in-call screen.
              _pushCall(
                context,
                InCallScreen(phone: state.activePhone),
                replace: true,
              );
            } else if (prev != CallStatus.ringing &&
                prev != CallStatus.connecting &&
                prev != CallStatus.onHold) {
              // Active with no prior UI (e.g. cold start into an ongoing call).
              _pushCall(context, InCallScreen(phone: state.activePhone));
            }
          // ringing/connecting/onHold → InCallScreen is already up.
          case CallStatus.onHold:
            break; // InCallScreen renders the hold state itself.
          case CallStatus.idle:
            if (prev != CallStatus.idle) _dismissCallRoute();
        }
      },
      child: widget.child,
    );
  }
}
