import 'package:flutter/material.dart';

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
    final scheme = Theme.of(context).colorScheme;
    // A rounded tonal card floating on the page — the shape Google Messages
    // uses for its own inline prompts, not a full-bleed strip.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'برای همگام‌سازی کامل پیامک‌ها، این برنامه را '
                'پیام‌رسان پیش‌فرض کنید',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: onDismiss,
                    child: Text(
                      'بعداً',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton(
                    onPressed: onRequest,
                    child: Text(
                      'تنظیم به عنوان پیش‌فرض',
                      style: TextStyle(color: scheme.primary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
