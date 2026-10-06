import 'package:flutter/material.dart';

import 'secure_lock_button.dart';

/// What a screen of the secure section shows while the section is locked:
/// why it is empty, and the one way to open it.
class SecureLockedView extends StatelessWidget {
  const SecureLockedView({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(
              // Through the same door as the lock icon: a phone with no
              // 6-digit PIN yet is asked to set one, not for a PIN it lacks.
              onPressed: () => openSecureSection(context),
              child: const Text('باز کردن بخش امن'),
            ),
          ],
        ),
      ),
    );
  }
}
