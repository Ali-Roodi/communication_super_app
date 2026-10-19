import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/authentication/models/pin_policy.dart';
import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';

/// Six digits of the secure section's PIN, for a step that needs it without
/// opening the section — the current PIN before changing it or turning the
/// fingerprint on, and the new PIN (typed twice, [confirm]).
///
/// [check] runs on the full entry and answers what to say when it is refused
/// (null: accepted). Pops the accepted PIN; back pops null.
class SecurePinEntryScreen extends StatefulWidget {
  const SecurePinEntryScreen({
    super.key,
    required this.title,
    required this.subtitle,
    this.confirm = false,
    this.check,
  });

  final String title;
  final String subtitle;

  /// Typed twice, both the same.
  final bool confirm;
  final Future<String?> Function(String pin)? check;

  @override
  State<SecurePinEntryScreen> createState() => _SecurePinEntryScreenState();
}

class _SecurePinEntryScreenState extends State<SecurePinEntryScreen> {
  static const int _length = PinPolicy.secureLength;

  String _pin = '';
  String? _first;
  String? _error;
  bool _checking = false;

  void _onKey(String digit) {
    if (_checking || _pin.length >= _length) return;
    HapticFeedback.lightImpact();
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == _length) _complete();
  }

  void _onDelete() {
    if (_checking || _pin.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _complete() async {
    if (widget.confirm && _first == null) {
      setState(() {
        _first = _pin;
        _pin = '';
      });
      return;
    }
    if (widget.confirm && _first != _pin) {
      _refuse('دو رمز یکسان نبودند؛ دوباره وارد کنید');
      return;
    }
    final check = widget.check;
    if (check != null) {
      setState(() => _checking = true);
      final refusal = await check(_pin);
      if (!mounted) return;
      setState(() => _checking = false);
      if (refusal != null) {
        _refuse(refusal);
        return;
      }
    }
    Navigator.of(context).pop(_pin);
  }

  void _refuse(String message) {
    HapticFeedback.heavyImpact();
    setState(() {
      _pin = '';
      _first = null;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final again = widget.confirm && _first != null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'رمز بخش امن'),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              Icon(
                Icons.lock_outline,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                again ? 'رمز را دوباره وارد کنید' : widget.title,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              PinDots(length: _length, filled: _pin.length),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: _checking
                    ? const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _error == null
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
