import 'package:flutter/material.dart';

/// Messages bottom-nav icon with an unread-count [Badge].
///
/// The badge is hidden when [unread] is 0 and caps its label at "99+".
/// [filled] selects the active (filled) vs. inactive (outline) chat icon.
class MessageNavIcon extends StatelessWidget {
  final int unread;
  final bool filled;

  const MessageNavIcon({super.key, required this.unread, required this.filled});

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: unread > 0,
      label: Text(unread > 99 ? '99+' : '$unread'),
      child: Icon(filled ? Icons.chat_bubble : Icons.chat_bubble_outline),
    );
  }
}
