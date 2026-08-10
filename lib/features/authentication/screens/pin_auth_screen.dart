import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import 'recovery_code_screen.dart';
import 'widgets/pin_pad.dart';

class PinAuthScreen extends StatefulWidget {
  const PinAuthScreen({super.key});

  @override
  State<PinAuthScreen> createState() => _PinAuthScreenState();
}

class _PinAuthScreenState extends State<PinAuthScreen> {
  String _pin = '';

  void _onNumberPressed(String number) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_pin.length < 4) {
        _pin += number;
        if (_pin.length == 4) {
          context.read<AuthBloc>().add(ValidatePin(_pin));
        }
      }
    });
  }

  void _onDelete() {
    HapticFeedback.lightImpact();
    setState(() {
      if (_pin.isNotEmpty) {
        _pin = _pin.substring(0, _pin.length - 1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is AuthValidationFailure) {
          HapticFeedback.heavyImpact();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(state.error)));
          setState(() => _pin = '');
        }
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock, size: 64, color: Colors.grey),
                const SizedBox(height: 24),
                Text(
                  'رمز عبور را وارد کنید',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 40),
                PinDots(filled: _pin.length),
                const SizedBox(height: 60),
                PinKeypad(onKey: _onNumberPressed, onDelete: _onDelete),
                const SizedBox(height: 8),
                // A forgotten PIN used to be a permanent lockout — this is the
                // way back in, via the code issued when the PIN was set.
                const ForgotPinButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
