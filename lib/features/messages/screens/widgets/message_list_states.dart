import 'package:flutter/material.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';

/// Full-screen placeholder shown when the inbox has no conversations yet.
class MessagesEmptyState extends StatelessWidget {
  const MessagesEmptyState({super.key});

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.chat_bubble_outline,
    title: 'هیچ پیامکی موجود نیست',
    subtitle: 'پیام‌های شما در اینجا نمایش داده خواهند شد',
  );
}

/// Centered "no search results" message.
class MessagesNoResults extends StatelessWidget {
  const MessagesNoResults({super.key});

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.search_off,
    title: 'نتیجه‌ای یافت نشد',
  );
}

/// Full-screen error state with a retry button.
class MessagesErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const MessagesErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'خطا در بارگذاری پیام‌ها',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: theme.textTheme.bodyLarge?.color,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: TextStyle(
                fontSize: 14,
                color: theme.textTheme.bodyMedium?.color,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('تلاش مجدد'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Colored background revealed behind a thread row while swiping (archive /
/// toggle-read). [alignStart] places the icon+label at the leading edge.
class ThreadSwipeBackground extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final bool alignStart;

  const ThreadSwipeBackground({
    super.key,
    required this.color,
    required this.icon,
    required this.label,
    required this.alignStart,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color.withValues(alpha: 0.85),
      alignment: alignStart
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.centerEnd,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}
