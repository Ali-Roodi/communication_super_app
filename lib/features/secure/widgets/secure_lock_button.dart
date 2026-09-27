import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/features/authentication/screens/pin_setup_screen.dart';
import '../bloc/secure_session_bloc.dart';
import '../screens/secure_unlock_screen.dart';

/// The closed/open lock at the top of every tab (matrix row 3): shows or hides
/// the secure section.
///
/// Absent in the commercial edition. It never says whether the section holds
/// anything — a closed lock over an empty section and over a full one look the
/// same.
class SecureLockButton extends StatelessWidget {
  const SecureLockButton({super.key, this.color});

  /// Icon colour; the header it sits in decides.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final status = context.select<SecureSessionBloc, SecureStatus>(
      (bloc) => bloc.state.status,
    );
    if (status == SecureStatus.unavailable) return const SizedBox.shrink();
    final open = status == SecureStatus.unlocked;
    return IconButton(
      icon: Icon(open ? Icons.lock_open : Icons.lock_outline),
      color: color,
      tooltip: open ? 'قفل کردن بخش امن' : 'باز کردن بخش امن',
      onPressed: () => _onPressed(context, status),
    );
  }

  Future<void> _onPressed(BuildContext context, SecureStatus status) async {
    HapticFeedback.selectionClick();
    final bloc = context.read<SecureSessionBloc>();
    switch (status) {
      case SecureStatus.unlocked:
        bloc.add(const SecureLockRequested());
      case SecureStatus.needsPin:
        await _askForPin(context);
      case SecureStatus.notCreated:
      case SecureStatus.locked:
      case SecureStatus.broken:
        await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => const SecureUnlockScreen()),
        );
      case SecureStatus.unavailable:
        break;
    }
  }

  /// The section opens with the app PIN; there has to be one first.
  Future<void> _askForPin(BuildContext context) async {
    final setPin = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('رمز برنامه لازم است'),
          content: const Text(
            'بخش امن با رمز ورود به برنامه باز می‌شود. ابتدا برای برنامه رمز '
            'تعیین کنید.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('تعیین رمز'),
            ),
          ],
        ),
      ),
    );
    if (setPin != true || !context.mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const PinSetupScreen(fromSettings: true),
      ),
    );
    if (context.mounted) {
      context.read<SecureSessionBloc>().add(const SecureSessionRefresh());
    }
  }
}
