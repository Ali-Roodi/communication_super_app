import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_state.dart';
import 'pin_auth_screen.dart';
import 'auth_choice_screen.dart';
import 'package:communication_super_app/core/navigation/main_navigation.dart';
import 'package:communication_super_app/core/widgets/permission_gate.dart';
import 'package:communication_super_app/core/widgets/default_app_gate.dart';

class AuthWrapperScreen extends StatelessWidget {
  const AuthWrapperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      // Transient states are for the screen on top to react to, never a
      // reason to swap it out. Building on them unmounted the PIN screen the
      // moment a PIN was checked — `AuthLoading`, then `AuthValidationFailure`,
      // both of which render as the blank fallback below — so a single wrong
      // PIN left a blank screen with no keypad and no way in short of killing
      // the app. Keeping the screen mounted is also what lets its listener
      // hear the failure and say so.
      buildWhen: (_, next) =>
          next is! AuthLoading &&
          next is! AuthValidationFailure &&
          next is! AuthRecoveryCodeIssued,
      builder: (context, state) {
        if (state is AuthLoading) {
          // Blank, not a spinner — this is a secure-storage read that resolves
          // in a few frames on the way from the launch splash to the app, and
          // a spinner in that gap is the whole of "it shows a loading screen
          // every time I open it". See [PermissionGate] for the same call.
          return const Scaffold(body: SizedBox.shrink());
        }

        if (state is AuthNotSet) {
          // Auth is optional: offer set-PIN / continue-without instead of
          // forcing the setup screen.
          return const AuthChoiceScreen();
        }

        if (state is AuthSet) {
          return const PinAuthScreen();
        }

        if (state is AuthAuthenticated) {
          // PermissionGate checks/requests all runtime permissions BEFORE
          // building MainNavigation.  This prevents the crash caused by
          // multiple screens (IndexedStack) simultaneously requesting
          // permissions and kicking off heavy data-loads right after the
          // last dialog is dismissed.
          // DefaultAppGate then asks for the two default-app roles — after the
          // runtime permissions, and with its own screen rather than a system
          // dialog fired on our behalf.
          return const PermissionGate(
            child: DefaultAppGate(child: MainNavigation()),
          );
        }

        return const Scaffold(body: SizedBox.shrink());
      },
    );
  }
}
