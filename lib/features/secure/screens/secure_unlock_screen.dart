import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/authentication/models/pin_policy.dart';
import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import 'package:communication_super_app/features/authentication/services/biometric_unlock.dart';
import '../bloc/secure_session_bloc.dart';

/// The secure section's own PIN: set the first time (which creates the
/// section), asked for every time after — or the fingerprint, when
/// «باز کردن با اثر انگشت» is on. Pops `true` once it is open.
///
/// The PIN is 6 digits and is never the app PIN. Forgetting it loses what is
/// inside: «رمز بخش امن را فراموش کرده‌ام» deletes the section, after saying
/// so, and starts a new one.
class SecureUnlockScreen extends StatefulWidget {
  const SecureUnlockScreen({super.key});

  @override
  State<SecureUnlockScreen> createState() => _SecureUnlockScreenState();
}

class _SecureUnlockScreenState extends State<SecureUnlockScreen> {
  static const int _length = PinPolicy.secureLength;

  String _pin = '';

  /// Creating: the first entry, kept while it is typed again.
  String? _firstEntry;

  /// A note of the screen's own (a mismatch while creating); the bloc's
  /// failure message is shown otherwise.
  String? _note;

  SecureSessionBloc get _bloc => context.read<SecureSessionBloc>();

  void _onKey(String digit) {
    final state = _bloc.state;
    if (state.busy || _pin.length >= _length) return;
    HapticFeedback.lightImpact();
    setState(() {
      _pin += digit;
      _note = null;
    });
    if (_pin.length < _length) return;
    if (state.status == SecureStatus.notCreated) {
      _onCreateEntry();
    } else {
      _bloc.add(SecureUnlockRequested(_pin));
    }
  }

  void _onCreateEntry() {
    final first = _firstEntry;
    if (first == null) {
      setState(() {
        _firstEntry = _pin;
        _pin = '';
      });
      return;
    }
    if (first != _pin) {
      HapticFeedback.heavyImpact();
      setState(() {
        _firstEntry = null;
        _pin = '';
        _note = 'دو رمز یکسان نبودند؛ دوباره تعیین کنید';
      });
      return;
    }
    _bloc.add(SecureCreateRequested(_pin));
  }

  void _onDelete() {
    if (_pin.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _onStateChanged(BuildContext context, SecureSessionState state) {
    if (state.isUnlocked) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true);
      return;
    }
    if (!state.busy && state.lastFailure != null) {
      HapticFeedback.heavyImpact();
      setState(() {
        _pin = '';
        // A refused new PIN (the app PIN) starts the choice over.
        _firstEntry = null;
      });
    }
  }

  Future<BiometricUnlockOutcome> _biometric() async {
    final done = Completer<SecureBiometricOutcome>();
    _bloc.add(SecureBiometricUnlockRequested(done: done));
    return switch (await done.future) {
      SecureBiometricOutcome.unlocked => BiometricUnlockOutcome.unlocked,
      SecureBiometricOutcome.cancelled => BiometricUnlockOutcome.cancelled,
      // The key hides itself; the bloc's message says why.
      SecureBiometricOutcome.invalidated => BiometricUnlockOutcome.notEnabled,
      SecureBiometricOutcome.unavailable => BiometricUnlockOutcome.unavailable,
    };
  }

  Future<void> _forgot() async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('رمز بخش امن را فراموش کرده‌اید؟'),
          content: const Text(
            'این رمز راه بازیابی ندارد. تنها راه، حذف بخش امن و ساختن دوباره '
            'آن است: همهٔ پیام‌های رمز، دفترچهٔ پنهان، کلیدها و هرچه در بخش '
            'امن است برای همیشه پاک می‌شود. رمز برنامه تغییری نمی‌کند.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('حذف و ساخت دوباره'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _pin = '';
      _firstEntry = null;
      _note = null;
    });
    _bloc.add(const SecureResetRequested());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocConsumer<SecureSessionBloc, SecureSessionState>(
      listenWhen: (a, b) =>
          a.isUnlocked != b.isUnlocked || a.failures != b.failures,
      listener: _onStateChanged,
      builder: (context, state) {
        final creating = state.status == SecureStatus.notCreated;
        final broken = state.status == SecureStatus.broken;
        final confirming = creating && _firstEntry != null;
        final String title;
        final String explanation;
        if (creating) {
          title = confirming
              ? 'رمز را دوباره وارد کنید'
              : 'رمز بخش امن را تعیین کنید';
          explanation =
              'یک رمز ۶ رقمی، جدا از رمز برنامه، که فقط بخش امن را باز '
              'می‌کند. اگر فراموشش کنید، محتوای بخش امن برای همیشه از دست '
              'می‌رود.';
        } else if (broken) {
          title = 'بخش امن باز نمی‌شود';
          explanation =
              'کلید بخش امن روی این گوشی دیگر در دسترس نیست و محتوای آن قابل '
              'بازگرداندن نیست. می‌توانید آن را حذف و از نو بسازید.';
        } else {
          title = 'رمز بخش امن را وارد کنید';
          explanation = state.biometricOn
              ? 'با رمز بخش امن یا اثر انگشت باز می‌شود و با خروج از برنامه '
                    'دوباره قفل می‌شود.'
              : 'با رمز بخش امن باز می‌شود و با خروج از برنامه دوباره قفل '
                    'می‌شود.';
        }
        final message = _note ?? state.failureMessage;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: RtlAppBar(title: creating ? 'ساخت بخش امن' : 'بخش امن'),
            body: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  Icon(
                    broken ? Icons.error_outline : Icons.lock_outline,
                    size: 48,
                    color: broken
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      explanation,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (!broken) PinDots(length: _length, filled: _pin.length),
                  const SizedBox(height: 12),
                  // Said on the screen, like RelockScreen: a message somewhere
                  // else is a message nobody reads.
                  SizedBox(
                    height: 48,
                    child: state.busy
                        ? const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : message == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              message,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                  ),
                  const Spacer(),
                  if (broken)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: FilledButton.tonal(
                        onPressed: state.busy ? null : _forgot,
                        child: const Text('حذف و ساخت دوباره'),
                      ),
                    )
                  else ...[
                    PinKeypad(
                      onKey: _onKey,
                      onDelete: _onDelete,
                      enabled: !state.busy,
                      leading: creating
                          ? null
                          : BiometricUnlockKey(
                              // A fresh key when it is switched on or off, so
                              // its own "enabled" is read again.
                              key: ValueKey(state.biometricOn),
                              isEnabled: () async =>
                                  _bloc.state.biometricOn &&
                                  _bloc.state.status == SecureStatus.locked,
                              attempt: _biometric,
                              // Strong biometrics only: the fingerprint.
                              label: 'باز کردن با اثر انگشت',
                              // Unlocking pops the screen through the bloc.
                              onUnlocked: () async {},
                              // The bloc's own message is on the screen.
                              onMessage: (_) {},
                            ),
                    ),
                    SizedBox(
                      height: 48,
                      child: creating
                          ? null
                          : TextButton(
                              onPressed: state.busy ? null : _forgot,
                              child: const Text(
                                'رمز بخش امن را فراموش کرده‌ام',
                              ),
                            ),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
