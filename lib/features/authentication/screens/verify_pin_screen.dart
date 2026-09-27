import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import '../models/pin_policy.dart';
import '../repositories/auth_repository.dart';
import '../repositories/pin_attempt_limiter.dart';
import 'widgets/pin_pad.dart';

/// Asks for the current app PIN and pops it once it checks out.
///
/// Used before the PIN is changed: whoever is holding an unlocked phone must
/// not be able to replace the PIN without knowing it — and the secure section,
/// which opens with that PIN, needs the old one to re-seal its key. The check
/// goes through the shared attempt budget like every other PIN entry.
class VerifyPinScreen extends StatefulWidget {
  const VerifyPinScreen({super.key, this.repository});

  final AuthRepository? repository;

  @override
  State<VerifyPinScreen> createState() => _VerifyPinScreenState();
}

class _VerifyPinScreenState extends State<VerifyPinScreen> {
  late final AuthRepository _repository = widget.repository ?? AuthRepository();

  /// Digits in the stored PIN, read when the screen opens; keys are ignored
  /// until it is known, so a 6-digit PIN is never submitted at 4.
  int? _pinLength;

  @override
  void initState() {
    super.initState();
    _repository.pinLength().then((length) {
      if (mounted) setState(() => _pinLength = length);
    });
  }

  String _pin = '';
  bool _checking = false;
  String? _error;

  void _onKey(String digit) {
    final length = _pinLength;
    if (length == null || _checking || _pin.length >= length) return;
    HapticFeedback.lightImpact();
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == length) _verify();
  }

  void _onDelete() {
    if (_checking || _pin.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _verify() async {
    setState(() => _checking = true);
    final pin = _pin;
    final ok = await _repository.validatePin(pin);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(pin);
      return;
    }
    final wait = await _repository.pinRetryAfter();
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _pin = '';
      _checking = false;
      _error = wait == null
          ? 'رمز عبور اشتباه است'
          : PinAttemptLimiter.lockoutMessage(wait);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'تغییر رمز عبور'),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 40),
              Text(
                'رمز فعلی را وارد کنید',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 32),
              PinDots(
                length: _pinLength ?? PinPolicy.standardLength,
                filled: _pin.length,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: _error == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
              ),
              const Spacer(),
              PinKeypad(
                onKey: _onKey,
                onDelete: _onDelete,
                enabled: !_checking,
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
