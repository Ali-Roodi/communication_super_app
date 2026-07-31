import 'package:flutter/material.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'emoji_panel.dart';
import 'message_bubble.dart';
import 'schedule_send_sheet.dart';

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
    this.focusNode,
    this.onStickerBackspace,
    this.stickerPanelHeight = 280,
    this.onSchedule,
    this.scheduledAt,
    this.scheduleSummary,
    this.onClearSchedule,
    this.onEditSchedule,
  });

  final TextEditingController controller;
  final bool showStickers;
  final VoidCallback onToggleStickers;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final ValueChanged<String> onStickerSelected;

  /// The text field's focus, owned by the parent so it can re-focus the field
  /// when the emoji panel closes — the keyboard button used to only hide the
  /// panel and leave the user with no keyboard at all.
  final FocusNode? focusNode;

  /// Deletes one character before the cursor, for the emoji panel's backspace.
  final VoidCallback? onStickerBackspace;

  /// Height the emoji panel is drawn at — the parent passes the last measured
  /// keyboard height so the panel occupies exactly the keyboard's space and the
  /// chat does not jump when the two swap.
  final double stickerPanelHeight;

  /// Long-press on the send button → the «زمان‌بندی ارسال» sheet.
  final VoidCallback? onSchedule;

  /// When set, the composer is armed to schedule instead of send: a banner
  /// names the time and the send button turns into a scheduled-send button.
  final DateTime? scheduledAt;

  /// Repeat rule and jitter window in words («هر روز · تا ۳۰ دقیقه پراکندگی»),
  /// shown next to the time. Null renders just the time — see
  /// [scheduleDetailSummary].
  final String? scheduleSummary;

  /// Drops the pending schedule and returns the composer to sending now.
  final VoidCallback? onClearSchedule;

  /// Tapping the banner re-opens the schedule sheet on the armed choice, so the
  /// time / repeat / jitter can be corrected without clearing and starting over.
  final VoidCallback? onEditSchedule;

  /// Deletes the character (not the code unit — an emoji is a whole grapheme)
  /// before the cursor. Used when the parent supplies no [onStickerBackspace].
  void _backspace() {
    final value = controller.value;
    final selection = value.selection;
    if (!selection.isValid) return;
    if (!selection.isCollapsed) {
      controller.value = value.copyWith(
        text: value.text.replaceRange(selection.start, selection.end, ''),
        selection: TextSelection.collapsed(offset: selection.start),
        composing: TextRange.empty,
      );
      return;
    }
    final end = selection.start;
    if (end <= 0) return;
    // Walk back over the surrogate pair / ZWJ sequence so one press removes one
    // visible emoji instead of half of it.
    var start = end - 1;
    while (start > 0) {
      final unit = value.text.codeUnitAt(start);
      final previous = value.text.codeUnitAt(start - 1);
      final isLowSurrogate = unit >= 0xDC00 && unit <= 0xDFFF;
      final isHighSurrogate = previous >= 0xD800 && previous <= 0xDBFF;
      final joins =
          unit == 0x200D || previous == 0x200D || unit == 0xFE0F;
      if ((isLowSurrogate && isHighSurrogate) || joins) {
        start--;
        continue;
      }
      break;
    }
    controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
      composing: TextRange.empty,
    );
  }

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
            if (scheduledAt != null)
              _ScheduleBanner(
                at: scheduledAt!,
                summary: scheduleSummary,
                onClear: onClearSchedule,
                onEdit: onEditSchedule,
              ),
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
            // Google Messages' composer: everything except the send button
            // lives inside one filled pill; the circular send sits beside it.
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          tooltip: 'پیوست',
                          onPressed: onAttach,
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: TextField(
                              controller: controller,
                              focusNode: focusNode,
                              minLines: 1,
                              maxLines: 4,
                              textInputAction: TextInputAction.newline,
                              style: const TextStyle(fontSize: 16),
                              decoration: const InputDecoration(
                                hintText: 'پیامک',
                                isDense: true,
                                filled: false,
                                contentPadding: EdgeInsets.zero,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
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
                          tooltip: showStickers ? 'صفحه‌کلید' : 'ایموجی',
                          onPressed: onToggleStickers,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                MessageSendButton(
                  enabled: hasText,
                  onSend: onSend,
                  onSchedule: onSchedule,
                  scheduled: scheduledAt != null,
                ),
              ],
            ),
            if (showStickers)
              EmojiPanel(
                height: stickerPanelHeight,
                onSelected: onStickerSelected,
                onBackspace: onStickerBackspace ?? _backspace,
              ),
          ],
        ),
      ),
    );
  }
}

/// The strip above the composer while a send is scheduled — Google Messages
/// keeps the chosen time in front of the user until the message is sent.
///
/// The strip itself is a button: tapping it re-opens the schedule sheet on the
/// armed choice ([onEdit]). Only the ✕ clears the schedule, so a mistyped time
/// is corrected instead of thrown away.
class _ScheduleBanner extends StatelessWidget {
  const _ScheduleBanner({
    required this.at,
    this.summary,
    this.onClear,
    this.onEdit,
  });

  final DateTime at;
  final String? summary;
  final VoidCallback? onClear;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
            child: Row(
              children: [
                Icon(
                  Icons.schedule,
                  size: 18,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ارسال در ${formatScheduleLabel(at)}'
                    '${(summary == null || summary!.isEmpty) ? '' : ' · $summary'}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                if (onEdit != null)
                  Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'لغو زمان‌بندی',
                  color: theme.colorScheme.onSecondaryContainer,
                  onPressed: onClear,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

