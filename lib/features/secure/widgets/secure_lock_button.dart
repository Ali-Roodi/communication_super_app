import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';

import '../bloc/secure_session_bloc.dart';
import '../screens/secure_unlock_screen.dart';
import '../services/secure_unread_badge.dart';

/// The closed/open lock at the top of every tab (matrix row 3): shows or hides
/// the secure section.
///
/// Absent in the commercial edition. It says nothing of what the section
/// holds, with one exception the mentor asked for: how many messages are
/// unread in it ([SecureUnreadBadge]) — a number, as «N پیام رمز جدید» already
/// says on the notification shade, never who or what. It stays until those
/// messages are shown, whatever happens to the notification.
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
    final counts =
        status == SecureStatus.locked || status == SecureStatus.unlocked;
    final icon = Icon(open ? Icons.lock_open : Icons.lock_outline);
    final action = open ? 'قفل کردن بخش امن' : 'باز کردن بخش امن';
    IconButton button(int unread) => IconButton(
      icon: unread == 0
          ? icon
          : Badge(
              // The tooltip says the number; read out on its own it would
              // replace the button's name with a bare «۲».
              label: ExcludeSemantics(
                child: Text(
                  PersianUtils.toPersianNumber(unread > 99 ? '99+' : '$unread'),
                ),
              ),
              child: icon,
            ),
      color: color,
      tooltip: unread == 0
          ? action
          : '$action، ${PersianUtils.toPersianNumber('$unread')} '
                'پیام رمز خوانده‌نشده',
      onPressed: () => _onPressed(context, status),
    );
    if (!counts) return button(0);
    return ValueListenableBuilder<int>(
      valueListenable: SecureUnreadBadge.count,
      builder: (context, unread, _) => button(unread),
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
