import 'package:flutter/material.dart';

import '../screens/secure_unlock_screen.dart';

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
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const SecureUnlockScreen()),
              ),
              child: const Text('باز کردن بخش امن'),
            ),
          ],
        ),
      ),
    );
  }
}
