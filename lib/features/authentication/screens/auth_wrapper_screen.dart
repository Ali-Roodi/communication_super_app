import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_state.dart';
import 'pin_auth_screen.dart';
import 'pin_setup_screen.dart';
import 'package:communication_super_app/core/navigation/main_navigation.dart';

class AuthWrapperScreen extends StatelessWidget {
  const AuthWrapperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      builder: (context, state) {
        if (state is AuthLoading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (state is AuthNotSet) {
          return const PinSetupScreen();
        }

        if (state is AuthSet) {
          return const PinAuthScreen();
        }

        if (state is AuthAuthenticated) {
          return const MainNavigation();
        }

        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}


