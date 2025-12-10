import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/services/app_lock_service.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';

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
          const SnackBar(
            content: Text('PIN اشتباه است'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.lock,
                size: 64,
                color: Colors.grey,
              ),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (index) {
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey),
                      color: index < _pin.length
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 60),
              _buildKeypad(),
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
    );
  }

  Widget _buildKeypad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: ['1', '2', '3'].map((number) => _buildKey(number)).toList(),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: ['4', '5', '6'].map((number) => _buildKey(number)).toList(),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: ['7', '8', '9'].map((number) => _buildKey(number)).toList(),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const SizedBox(width: 80),
              _buildKey('0'),
              _buildDeleteKey(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKey(String number) {
    return InkWell(
      onTap: _isAuthenticating ? null : () => _onNumberPressed(number),
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Center(
          child: Text(
            number,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _buildDeleteKey() {
    return InkWell(
      onTap: _isAuthenticating ? null : _onDelete,
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: const Icon(Icons.backspace, size: 24),
      ),
    );
  }
}

