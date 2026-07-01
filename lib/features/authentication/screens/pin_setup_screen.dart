import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'widgets/pin_pad.dart';

class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String _pin = '';
  String _confirmPin = '';
  bool _isConfirming = false;

  void _onNumberPressed(String number) {
    HapticFeedback.lightImpact();
    setState(() {
      if (!_isConfirming) {
        if (_pin.length < 4) _pin += number;
        if (_pin.length == 4) _isConfirming = true;
      } else {
        if (_confirmPin.length < 4) _confirmPin += number;
        if (_confirmPin.length == 4) {
          if (_pin == _confirmPin) {
            context.read<AuthBloc>().add(SetPin(_pin));
          } else {
            HapticFeedback.heavyImpact();
            _showError('رمزهای عبور یکسان نیستند');
            _reset();
          }
        }
      }
    });
  }

  void _onDelete() {
    HapticFeedback.lightImpact();
    setState(() {
      if (_isConfirming && _confirmPin.isNotEmpty) {
        _confirmPin = _confirmPin.substring(0, _confirmPin.length - 1);
      } else if (_isConfirming) {
        // Backing out of the confirm step returns to editing the first entry.
        _isConfirming = false;
      } else if (_pin.isNotEmpty) {
        _pin = _pin.substring(0, _pin.length - 1);
      }
    });
  }

  void _reset() {
    setState(() {
      _pin = '';
      _confirmPin = '';
      _isConfirming = false;
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is AuthValidationFailure) {
          _showError(state.error);
          _reset();
        }
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: const RtlAppBar(title: 'تنظیم رمز عبور'),
          body: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 40),
                Text(
                  _isConfirming ? 'تکرار رمز عبور' : 'رمز عبور را وارد کنید',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 40),
                PinDots(filled: _isConfirming ? _confirmPin.length : _pin.length),
                const Spacer(),
                PinKeypad(onKey: _onNumberPressed, onDelete: _onDelete),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
