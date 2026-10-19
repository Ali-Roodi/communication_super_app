import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
    if (status == SecureStatus.unlocked) {
      context.read<SecureSessionBloc>().add(const SecureLockRequested());
      return;
    }
    await openSecureSection(context);
  }
}

/// The one way into the secure section, for every «باز کردن بخش امن» — the
/// lock icon, the button a locked screen shows ([SecureLockedView]) and the
/// «پیام رمز جدید» notification. [SecureUnlockScreen] creates the section
/// the first time (it sets the section's own PIN) and opens it after.
Future<void> openSecureSection(BuildContext context) async {
  final status = context.read<SecureSessionBloc>().state.status;
  switch (status) {
    case SecureStatus.notCreated:
    case SecureStatus.locked:
    case SecureStatus.broken:
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const SecureUnlockScreen()),
      );
    case SecureStatus.unlocked:
    case SecureStatus.unavailable:
      break;
  }
}
