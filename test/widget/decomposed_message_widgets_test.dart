import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_composer.dart';
import 'package:communication_super_app/features/messages/screens/widgets/messages_app_bars.dart';
import 'package:communication_super_app/features/messages/screens/widgets/conversation_app_bars.dart';
import 'package:communication_super_app/features/messages/screens/widgets/thread_options_sheet.dart';
import 'package:communication_super_app/features/messages/screens/widgets/conversation_sheets.dart';

/// Covers the presentation widgets extracted from `messages_list_screen` and
/// `conversation_screen` — the safety net for that decomposition.
Widget _appBarHarness(PreferredSizeWidget appBar) => MaterialApp(
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(appBar: appBar),
  ),
);

Widget _bodyHarness(Widget child) => MaterialApp(
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(body: child),
  ),
);

MessageThread _thread({bool unread = false, bool pinned = false}) =>
    MessageThread(
      threadId: '09120000000',
      phoneNumber: '09120000000',
      contactName: 'علی',
      lastMessage: 'سلام',
      lastMessageTime: DateTime(2026, 1, 1, 12),
      unreadCount: unread ? 2 : 0,
      isPinned: pinned,
    );

void main() {
  group('MessageComposer', () {
    testWidgets(
      'send button is disabled for empty text and enabled with text',
      (tester) async {
        final empty = TextEditingController();
        var sends = 0;
        await tester.pumpWidget(
          _bodyHarness(
            MessageComposer(
              controller: empty,
              showStickers: false,
              onToggleStickers: () {},
              onAttach: () {},
              onSend: () => sends++,
              onStickerSelected: (_) {},
            ),
          ),
        );
        await tester.tap(find.byIcon(Icons.send));
        expect(sends, 0, reason: 'empty composer must not send');

        final filled = TextEditingController(text: 'سلام');
        await tester.pumpWidget(
          _bodyHarness(
            MessageComposer(
              controller: filled,
              showStickers: false,
              onToggleStickers: () {},
              onAttach: () {},
              onSend: () => sends++,
              onStickerSelected: (_) {},
            ),
          ),
        );
        await tester.tap(find.byIcon(Icons.send));
        expect(sends, 1);
      },
    );

    testWidgets('GSM text: 200 chars split into 2 segments', (tester) async {
      await tester.pumpWidget(
        _bodyHarness(
          MessageComposer(
            controller: TextEditingController(text: 'a' * 200),
            showStickers: false,
            onToggleStickers: () {},
            onAttach: () {},
            onSend: () {},
            onStickerSelected: (_) {},
          ),
        ),
      );
      // GSM-7: 160 per single, 153 per part → 200 chars = 2 پیامک. Long SMS is
      // multipart SMS, not MMS, so there is no "MMS" chip.
      expect(find.textContaining('۲ پیامک'), findsOneWidget);
      expect(find.text('MMS'), findsNothing);
    });

    testWidgets('Persian text splits at the 70-char UCS-2 boundary', (
      tester,
    ) async {
      await tester.pumpWidget(
        _bodyHarness(
          MessageComposer(
            controller: TextEditingController(text: 'ن' * 71),
            showStickers: false,
            onToggleStickers: () {},
            onAttach: () {},
            onSend: () {},
            onStickerSelected: (_) {},
          ),
        ),
      );
      // Unicode: 70 per single → 71 chars must already be 2 پیامک.
      expect(find.textContaining('۲ پیامک'), findsOneWidget);
    });

    testWidgets('the sticker panel is shown and taps fire onStickerSelected', (
      tester,
    ) async {
      String? picked;
      await tester.pumpWidget(
        _bodyHarness(
          MessageComposer(
            controller: TextEditingController(),
            showStickers: true,
            onToggleStickers: () {},
            onAttach: () {},
            onSend: () {},
            onStickerSelected: (s) => picked = s,
          ),
        ),
      );
      expect(find.text(MessageComposer.stickers.first), findsOneWidget);
      await tester.tap(find.text(MessageComposer.stickers.first));
      expect(picked, MessageComposer.stickers.first);
    });
  });

  group('MessagesSelectionAppBar', () {
    testWidgets('renders the count and fires the toolbar callbacks', (
      tester,
    ) async {
      var read = 0, archive = 0, del = 0;
      await tester.pumpWidget(
        _appBarHarness(
          MessagesSelectionAppBar(
            selectedCount: 3,
            onClear: () {},
            onMarkRead: () => read++,
            onArchive: () => archive++,
            onDelete: () => del++,
            onSelectAll: () {},
            onMarkUnread: () {},
            onBlock: () {},
          ),
        ),
      );
      expect(find.text('۳'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.mark_chat_read_outlined));
      await tester.tap(find.byIcon(Icons.archive_outlined));
      await tester.tap(find.byIcon(Icons.delete_outline));
      expect([read, archive, del], [1, 1, 1]);
    });

    testWidgets('overflow menu fires block', (tester) async {
      var blocked = 0;
      await tester.pumpWidget(
        _appBarHarness(
          MessagesSelectionAppBar(
            selectedCount: 1,
            onClear: () {},
            onMarkRead: () {},
            onArchive: () {},
            onDelete: () {},
            onSelectAll: () {},
            onMarkUnread: () {},
            onBlock: () => blocked++,
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('مسدود کردن'));
      expect(blocked, 1);
    });
  });

  group('ConversationAppBar', () {
    testWidgets(
      'shows the title, fires onCall, and offers "add" when unsaved',
      (tester) async {
        var calls = 0;
        String? menu;
        await tester.pumpWidget(
          _appBarHarness(
            ConversationAppBar(
              title: '۰۹۱۲۰۰۰۰۰۰۰',
              phoneNumber: '09120000000',
              hasName: false,
              onOpenContact: () {},
              onCall: () => calls++,
              onMenuSelected: (v) => menu = v,
            ),
          ),
        );
        expect(find.text('۰۹۱۲۰۰۰۰۰۰۰'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.call_outlined));
        expect(calls, 1);

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        expect(find.text('افزودن به مخاطبین'), findsOneWidget);
        await tester.tap(find.text('افزودن به مخاطبین'));
        expect(menu, 'add');
      },
    );
  });

  group('showThreadOptionsSheet', () {
    testWidgets('a row pops the sheet and fires its callback', (tester) async {
      // The 6-row sheet is taller than the default 800x600 test surface; give
      // it room so the last (delete) row is on-screen and hit-testable.
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var deleted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showThreadOptionsSheet(
                  context,
                  thread: _thread(),
                  onTogglePin: () {},
                  onToggleRead: () {},
                  onArchive: () {},
                  onBlock: () {},
                  onSelect: () {},
                  onDelete: () => deleted++,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف گفتگو'));
      await tester.pumpAndSettle();
      expect(deleted, 1);
      expect(find.text('حذف گفتگو'), findsNothing); // sheet closed
    });
  });

  group('showMessageOptionsSheet', () {
    testWidgets('copy row pops the sheet and fires onCopy', (tester) async {
      var copied = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showMessageOptionsSheet(
                  context,
                  onCopy: () => copied++,
                  onSelectText: () {},
                  onForward: () {},
                  onInfo: () {},
                  onSelect: () {},
                  onDelete: () {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('کپی'));
      await tester.pumpAndSettle();
      expect(copied, 1);
    });
  });
}
