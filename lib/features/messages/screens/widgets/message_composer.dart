import 'dart:ui' as ui;

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
    this.keyboardInset = 0,
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

  /// How much of the screen the system keyboard is covering right now.
  ///
  /// Passed in rather than read here, and that is not a style choice: a
  /// `Scaffold` **removes the bottom view inset from its body** (that is what
  /// `resizeToAvoidBottomInset` does), so a `MediaQuery` lookup from inside the
  /// composer reports `viewInsets.bottom == 0` with the keyboard fully up. The
  /// growth cap below is a height measured against the free screen, so reading
  /// it here meant the cap never knew about the keyboard at all — the field
  /// grew its full ten lines and, at a raised «اندازه متن پیام», the line being
  /// typed ended up underneath the keyboard. The parent reads the inset from
  /// its own context, which is above the Scaffold.
  final double keyboardInset;

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
      final joins = unit == 0x200D || previous == 0x200D || unit == 0xFE0F;
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

  // ── Growing field ──────────────────────────────────────────────────────────
  //
  // Google Messages' composer grows with the message and stops at ten-ish
  // lines, after which the text scrolls inside it (measured on the device:
  // ~11 lines, ~321 dp, then the box stops moving). These are the same rules.

  /// Ceiling on the field's growth, in lines.
  static const int _kMaxLines = 10;

  static const double _kFontSize = 16;

  /// Matches `bodyLarge` — the bubbles' line spacing, so a message looks the
  /// same while it is typed and after it is sent.
  static const double _kLineHeight = 1.45;

  /// Space the composer must leave for the app bar and a strip of conversation.
  /// Without it a ten-line message plus an open emoji panel is taller than the
  /// screen, and the composer's `Column` overflows.
  static const double _kReservedForChat = 200;

  /// How many lines fit above the keyboard (or the emoji panel) right now.
  ///
  /// The cap is a *height*, not a line count, so the field can never grow into
  /// the panel; on a tall screen with the keyboard down it resolves to the full
  /// [_kMaxLines].
  static int _maxLinesFor(
    BuildContext context,
    double panelHeight,
    double keyboardInset,
  ) {
    final media = MediaQuery.of(context);
    // The keyboard and the emoji panel never occupy the screen at once — the
    // panel is only drawn while the keyboard is down.
    final occupied = keyboardInset > panelHeight ? keyboardInset : panelHeight;
    final free =
        media.size.height - media.padding.top - occupied - _kReservedForChat;
    // The **scaled** line height, never the nominal one. «اندازه متن پیام»
    // (and Android's own font size) multiply this field's text like everything
    // else in the conversation, so a line is `textScaler.scale(16) * 1.45` tall
    // — at 200 % that is twice what this used to assume, and ten of them are
    // far more than the space above the keyboard. The field went on growing
    // past the screen and the line being typed slid underneath the keyboard,
    // which is exactly the report. Measuring in scaled pixels caps the growth
    // where it actually fits, and the field scrolls inside itself from there
    // with the caret's line kept in view.
    final lineHeight = media.textScaler.scale(_kFontSize) * _kLineHeight;
    final lines = (free / lineHeight).floor();
    return lines.clamp(1, _kMaxLines);
  }

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
    final remaining = (segments <= 1 ? single - len : segments * multi - len)
        .clamp(0, single);

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
                    // «۴۶/۹» — characters left in the current segment over the
                    // number of SMS the message will be sent as. Google
                    // Messages' own counter, verbatim, and it has to be drawn
                    // **left to right**: the words it used to carry («۴۶
                    // باقی‌مانده · ۹ پیامک») put a bidi-neutral separator
                    // between Persian text and a Persian digit, so the
                    // algorithm reordered the pieces and the middle dot came
                    // out looking like a Persian zero glued to the count —
                    // «۴۶ باقی‌مانده ۹۰ پیامک», a number the message never had.
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        '${PersianUtils.toPersianNumber('$remaining')}'
                        '/${PersianUtils.toPersianNumber('$segments')}',
                        style: theme.textTheme.bodySmall,
                      ),
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
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsetsDirectional.only(
                            start: 8,
                            end: 2,
                            top: 8,
                            bottom: 8,
                          ),
                        ),
                        // No SIM chip here. Google Messages puts the card on
                        // the conversation's details page and nowhere else, and
                        // a chip wedged between «+» and the hint text read as
                        // part of the composer's furniture rather than as the
                        // answer to «which card does this go out on» — which is
                        // a property of the conversation, asked once, not of
                        // every message being typed.
                        const SizedBox(width: 6),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: TextField(
                              controller: controller,
                              focusNode: focusNode,
                              minLines: 1,
                              // Grows line by line and then scrolls inside
                              // itself, exactly like Google Messages.
                              maxLines: _maxLinesFor(
                                context,
                                showStickers ? stickerPanelHeight : 0,
                                keyboardInset,
                              ),
                              textInputAction: TextInputAction.newline,
                              // Selecting what has been typed, at the same
                              // quality as selecting a bubble: the highlight
                              // covers the **whole line box** so a selection
                              // running over several lines is one continuous
                              // band instead of a row of ragged strips (this
                              // field's line height is 1.45, so `tight` leaves
                              // a visible gap between every pair of lines), and
                              // it stays **tight horizontally** so the empty
                              // part of a short line is never painted as
                              // selected. `BoxWidthStyle.max` is exactly the
                              // "it selects the blank space too" behaviour and
                              // is deliberately not used.
                              selectionHeightStyle: ui.BoxHeightStyle.max,
                              selectionWidthStyle: ui.BoxWidthStyle.tight,
                              style: const TextStyle(
                                fontSize: _kFontSize,
                                height: _kLineHeight,
                              ),
                              decoration: const InputDecoration(
                                // Just «پیامک». The SIM is already named by the
                                // chip immediately to its right, and repeating
                                // it in the hint made the empty composer read
                                // as two competing labels.
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
