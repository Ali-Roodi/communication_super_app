import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/services/app_lock_service.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/screens/app_lock_screen.dart';

class LockButton extends StatelessWidget {
  const LockButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.lock_outline_rounded),
      onPressed: () {
        final lockService = AppLockService();
        lockService.lock();
        final authBloc = context.read<AuthBloc>();
        authBloc.add(const LockApp());
        
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => const AppLockScreen(),
            fullscreenDialog: true,
          ),
        );
      },
    );
  }
}

