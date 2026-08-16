import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/services/app_lock_service.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'recovery_code_screen.dart';
import 'widgets/pin_pad.dart';

class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final AppLockService _lockService = AppLockService();
  String _pin = '';
  bool _isBiometricAvailable = false;
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    _checkBiometricAvailability();
    _tryBiometricAuth();
  }

  Future<void> _checkBiometricAvailability() async {
    final available = await _lockService.isBiometricAvailable();
    setState(() {
      _isBiometricAvailable = available;
    });
  }

  Future<void> _tryBiometricAuth() async {
    if (_isBiometricAvailable && !_isAuthenticating) {
      setState(() {
        _isAuthenticating = true;
      });

      final success = await _lockService.authenticateWithBiometric();

      if (success) {
        await _lockService.unlock();
        if (!mounted) return;
        final authBloc = context.read<AuthBloc>();
        authBloc.add(const Authenticate());
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        setState(() {
          _isAuthenticating = false;
        });
      }
    }
  }

  void _onNumberPressed(String number) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_pin.length < 4) {
        _pin += number;
        if (_pin.length == 4) {
          _validatePin();
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

  Future<void> _validatePin() async {
    setState(() {
      _isAuthenticating = true;
    });

    final isValid = await _lockService.authenticateWithPin(_pin);

    if (isValid) {
      await _lockService.unlock();
      if (!mounted) return;
      final authBloc = context.read<AuthBloc>();
      authBloc.add(const Authenticate());
      if (!mounted) return;
      Navigator.of(context).pop();
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _pin = '';
        _isAuthenticating = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('رمز عبور اشتباه است'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
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
                  'برنامه قفل شده است',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'برای ادامه، احراز هویت کنید',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 40),
                PinDots(filled: _pin.length),
                const SizedBox(height: 60),
                PinKeypad(
                  onKey: _onNumberPressed,
                  onDelete: _onDelete,
                  enabled: !_isAuthenticating,
                ),
                const SizedBox(height: 8),
                const ForgotPinButton(),
                if (_isBiometricAvailable && !_isAuthenticating) ...[
                  const SizedBox(height: 24),
                  IconButton(
                    icon: const Icon(Icons.fingerprint, size: 48),
                    onPressed: _tryBiometricAuth,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'احراز هویت بیومتریک',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
