import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/services/app_handoff.dart';

import '../bloc/secure_session_bloc.dart';

/// Locks the secure section the moment the app leaves the foreground (owner's
/// decision, 1405/07/05) and tells it when the app is back.
///
/// Only `paused`/`hidden` count as leaving, as in `AppLockWrapper`:
/// `inactive` fires for the notification shade, a permission dialog and an
/// incoming-call overlay, none of which take the user out of the app. Nor
/// does an [AppHandoff] — the key-file picker the app itself opened — as long
/// as the user is back within [AppHandoff.maxAway].
class SecureSessionGuard extends StatefulWidget {
  const SecureSessionGuard({super.key, required this.child});

  final Widget child;

  @override
  State<SecureSessionGuard> createState() => _SecureSessionGuardState();
}

class _SecureSessionGuardState extends State<SecureSessionGuard>
    with WidgetsBindingObserver {
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
    final bloc = context.read<SecureSessionBloc>();
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (_handoff.onPaused()) break;
        bloc.add(const SecureAppBackgrounded());
      case AppLifecycleState.resumed:
        if (_handoff.onResumed() == HandoffResume.overdue) {
          bloc.add(const SecureAppBackgrounded());
        }
        bloc.add(const SecureAppResumed());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
