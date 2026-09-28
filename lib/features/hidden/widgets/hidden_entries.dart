import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';

import '../bloc/hidden_bloc.dart';
import '../screens/hidden_calls_screen.dart';
import '../screens/hidden_contacts_screen.dart';

/// «دفترچه مخفی» at the top of the Contacts tab — there **only while the
/// secure section is open** (matrix row 3): with the lock closed nothing
/// hints that a hidden phonebook exists.
class HiddenContactsEntry extends StatelessWidget {
  const HiddenContactsEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final open = context.select<SecureSessionBloc, bool>(
      (b) => b.state.isUnlocked,
    );
    if (!open) return const SizedBox.shrink();
    final count = context.select<HiddenBloc, int>(
      (b) => b.state.contacts.length,
    );
    return SecureEntryRow(
      icon: Icons.contact_phone_outlined,
      title: 'دفترچه مخفی',
      trailing: count > 0 ? PersianUtils.toPersianNumber('$count') : null,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const HiddenContactsScreen())),
    );
  }
}

/// «تماس‌های مخفی» at the top of «اخیر», on the same terms.
class HiddenCallsEntry extends StatelessWidget {
  const HiddenCallsEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final open = context.select<SecureSessionBloc, bool>(
      (b) => b.state.isUnlocked,
    );
    if (!open) return const SizedBox.shrink();
    return SecureEntryRow(
      icon: Icons.phone_locked_outlined,
      title: 'تماس‌های مخفی',
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const HiddenCallsScreen())),
    );
  }
}

/// The tonal row a secure-section list is reached by.
class SecureEntryRow extends StatelessWidget {
  const SecureEntryRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  /// A count, drawn as a badge.
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: scheme.onPrimaryContainer),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onPrimaryContainer,
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
