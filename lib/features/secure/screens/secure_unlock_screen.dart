import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import '../bloc/secure_session_bloc.dart';

/// The app PIN, asked for to open (or, the first time, to create) the secure
/// section. Pops `true` once it is open.
class SecureUnlockScreen extends StatefulWidget {
  const SecureUnlockScreen({super.key});

  @override
  State<SecureUnlockScreen> createState() => _SecureUnlockScreenState();
}

class _SecureUnlockScreenState extends State<SecureUnlockScreen> {
  static const int _pinLength = 4;
  String _pin = '';

  void _onKey(String digit) {
    final state = context.read<SecureSessionBloc>().state;
    if (state.busy || _pin.length >= _pinLength) return;
    HapticFeedback.lightImpact();
    setState(() => _pin += digit);
    if (_pin.length == _pinLength) {
      context.read<SecureSessionBloc>().add(SecureUnlockRequested(_pin));
    }
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
      setState(() => _pin = '');
    }
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
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: RtlAppBar(title: creating ? 'ساخت بخش امن' : 'بخش امن'),
            body: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 32),
                  Icon(
                    broken ? Icons.error_outline : Icons.lock_outline,
                    size: 48,
                    color: broken
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'رمز برنامه را وارد کنید',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      creating
                          ? 'بخش امن با همین رمز باز می‌شود. اگر رمز برنامه را '
                                'فراموش کنید، محتوای بخش امن برای همیشه از دست '
                                'می‌رود.'
                          : 'بخش امن با رمز برنامه باز می‌شود و با خروج از '
                                'برنامه دوباره قفل می‌شود.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  PinDots(filled: _pin.length),
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
                        : state.failureMessage == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              state.failureMessage!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                  ),
                  const Spacer(),
                  if (broken)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'کلید بخش امن روی این گوشی دیگر در دسترس نیست. از '
                        'تنظیمات ← امنیت ← «بخش امن» می‌توانید آن را حذف و از نو '
                        'بسازید.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  else
                    PinKeypad(
                      onKey: _onKey,
                      onDelete: _onDelete,
                      enabled: !state.busy,
                    ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
