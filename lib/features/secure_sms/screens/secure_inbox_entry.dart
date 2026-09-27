import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';

import '../bloc/secure_messages_bloc.dart';
import 'secure_inbox_screen.dart';

/// The «پیام‌های رمز» row at the top of the inbox. There **only while the
/// secure section is open** (matrix row 3): with the lock closed nothing in
/// the app hints that encrypted conversations exist.
class SecureInboxEntry extends StatelessWidget {
  const SecureInboxEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final open = context.select<SecureSessionBloc, bool>(
      (b) => b.state.isUnlocked,
    );
    if (!open) return const SizedBox.shrink();
    final unread = context.select<SecureMessagesBloc, int>(
      (b) => b.state.totalUnread,
    );
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SecureInboxScreen())),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.lock, color: scheme.onPrimaryContainer),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'پیام‌های رمز',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                if (unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      PersianUtils.toPersianNumber('$unread'),
                      style: TextStyle(color: scheme.onPrimary, fontSize: 12),
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_left, color: scheme.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
