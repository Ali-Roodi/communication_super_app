import 'package:flutter/material.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
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

  /// Quick-pick emoji — tapping one inserts it at the cursor (so several can be
  /// combined before sending). Full emoji and any keyboard sticker packs remain
  /// available via the system keyboard.
  static const List<String> stickers = [
    // Smileys & emotion
    '😀', '😁', '😂', '🤣', '😊', '😇', '🙂', '😉', '😍', '🥰', '😘', '😋',
    '😎', '🤩', '🥳', '😏', '😌', '😔', '😢', '😭', '😤', '😡', '🤬', '😱',
    '😨', '😰', '😴', '🤔', '🤗', '🤭', '🙄', '😬', '🤒', '🤕', '🤢', '🥺',
    '😅', '😐', '😶', '🙃', '🤨', '😆', '💀', '👻', '🤡', '🥱',
    // Gestures & people
    '👍', '👎', '👏', '🙏', '🙌', '👌', '✌️', '🤞', '🤝', '💪', '👋', '🤙',
    '☝️', '✋', '🖐️', '👆', '👇', '👈', '👉', '💅',
    // Hearts & symbols
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💔', '❤️‍🔥', '💯', '✨',
    '🔥', '⭐', '🌟', '💫', '⚡', '✅', '❌', '❓', '❗', '💤',
    // Nature & food
    '🌹', '🌸', '🌻', '🌈', '☀️', '🌙', '☕', '🍵', '🍕', '🍔', '🍰', '🎂',
    '🍎', '🍓', '🍇', '🥤',
    // Activities & objects
    '🎉', '🎈', '🎁', '⚽', '🏆', '🎵', '🎬', '📱', '💻', '📞', '✈️', '🚗',
    '💰', '📌', '📝', '🔔',
  ];

  /// GSM-7 messages fit 160 chars per single SMS (153 per part when
  /// concatenated); Unicode (e.g. Persian) messages fit only 70 (67 per part).
  static bool _isUnicode(String s) => s.runes.any((r) => r > 0x7F);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = controller.text;
    final hasText = text.trim().isNotEmpty;
    final len = text.length;

    final unicode = _isUnicode(text);
    final single = unicode ? 70 : 160;
    final multi = unicode ? 67 : 153;
    final segments = len == 0 ? 0 : (len <= single ? 1 : (len / multi).ceil());
    // Surface the counter once the user nears the first-segment limit or the
    // message will split into more than one SMS.
    final showCounter = len > 0 && (segments > 1 || single - len <= 20);
    final remaining =
        (segments <= 1 ? single - len : segments * multi - len).clamp(0, single);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showCounter)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, right: 16, left: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      // «۱۲ باقی‌مانده · ۲ پیامک» — remaining chars in the
                      // current segment and the total segment count.
                      '${PersianUtils.toPersianNumber('$remaining')} باقی‌مانده'
                      ' · ${PersianUtils.toPersianNumber('$segments')} پیامک',
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
