import 'package:flutter/material.dart';

import 'nav_count_icon.dart';

/// Messages bottom-nav icon with an unread-count badge.
///
/// [filled] selects the active (filled) vs. inactive (outline) chat icon.
class MessageNavIcon extends StatelessWidget {
  final int unread;
  final bool filled;

  const MessageNavIcon({super.key, required this.unread, required this.filled});

  @override
  Widget build(BuildContext context) {
    return NavCountIcon(
      count: unread,
      icon: filled ? Icons.chat_bubble : Icons.chat_bubble_outline,
    );
  }
}
