import 'package:flutter/material.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';

/// Inbox banner asking the user to make this app the default SMS app.
///
/// Holding the SMS role is what makes SMS sync fully two-way: sent messages
/// get stored in the device provider (visible to every SMS app) and in-app
/// deletes remove the real provider rows. Without it the app can only mirror
/// device → app.
class DefaultSmsBanner extends StatelessWidget {
  final VoidCallback onRequest;
  final VoidCallback onDismiss;

  const DefaultSmsBanner({
    super.key,
    required this.onRequest,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sms_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'برای همگام‌سازی کامل پیامک‌ها، این برنامه را '
                    'پیام‌رسان پیش‌فرض کنید',
                    style: TextStyle(fontSize: 13.5),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onDismiss,
                  child: Text(
                    'بعداً',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                TextButton(
                  onPressed: onRequest,
                  child: const Text(
                    'تنظیم به عنوان پیش‌فرض',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
