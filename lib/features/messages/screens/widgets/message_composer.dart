import 'package:flutter/material.dart';
import 'message_bubble.dart';

/// The chat composer: SMS-segment counter, attachment button, text field,
/// sticker toggle, send button, and the emoji sticker panel.
///
/// Stateless by design — the parent `ConversationScreen` owns [controller] and
/// the [showStickers] flag and rebuilds this widget on every change, so the
/// segment counter and send-button enablement stay in sync.
class MessageComposer extends StatelessWidget {
  const MessageComposer({
    super.key,
    required this.controller,
    required this.showStickers,
    required this.onToggleStickers,
    required this.onAttach,
    required this.onSend,
    required this.onStickerSelected,
  });

  final TextEditingController controller;
  final bool showStickers;
  final VoidCallback onToggleStickers;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final ValueChanged<String> onStickerSelected;

  /// Emoji "stickers" — tapping one sends it immediately as a message, so no
  /// image assets are required.
  static const List<String> stickers = [
    '😀',
    '😂',
    '😍',
    '😎',
    '😭',
    '😡',
    '👍',
    '👎',
    '🙏',
    '👏',
    '🎉',
    '❤️',
    '🔥',
    '💯',
    '😴',
    '🤔',
    '😅',
    '😉',
    '😘',
    '🥳',
    '😱',
    '🤩',
    '💀',
    '✨',
    '🌹',
    '☕',
    '🍕',
    '⚽',
    '🎂',
    '🚗',
    '📱',
    '✅',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = controller.text;
    final hasText = text.trim().isNotEmpty;
    final len = text.length;
    final segments = len == 0 ? 0 : (len / 160).ceil();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (len > 140)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, right: 16, left: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (len > 160)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'MMS',
                          style: TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ),
                    Text(
                      '$len / $segments SMS',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'پیوست',
                  onPressed: onAttach,
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.brightness == Brightness.dark
                          ? theme.colorScheme.surfaceContainerHighest
                          : Colors.grey[200],
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              hintText: 'پیام',
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            showStickers
                                ? Icons.keyboard
                                : Icons.emoji_emotions_outlined,
                          ),
                          tooltip: 'استیکر',
                          onPressed: onToggleStickers,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                MessageSendButton(enabled: hasText, onSend: onSend),
              ],
            ),
            if (showStickers)
              _StickerPanel(onStickerSelected: onStickerSelected),
          ],
        ),
      ),
    );
  }
}

class _StickerPanel extends StatelessWidget {
  const _StickerPanel({required this.onStickerSelected});

  final ValueChanged<String> onStickerSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 220,
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: GridView.count(
        crossAxisCount: 6,
        padding: const EdgeInsets.all(8),
        children: [
          for (final s in MessageComposer.stickers)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onStickerSelected(s),
              child: Center(
                child: Text(s, style: const TextStyle(fontSize: 30)),
              ),
            ),
        ],
      ),
    );
  }
}
