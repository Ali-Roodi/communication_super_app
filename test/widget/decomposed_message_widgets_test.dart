import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_composer.dart';
import 'package:communication_super_app/features/messages/screens/widgets/messages_app_bars.dart';
import 'package:communication_super_app/features/messages/screens/widgets/conversation_app_bars.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_action_overlay.dart';

/// Covers the presentation widgets extracted from `messages_list_screen` and
/// `conversation_screen` — the safety net for that decomposition.
Widget _appBarHarness(PreferredSizeWidget appBar) => MaterialApp(
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(appBar: appBar),
  ),
);

/// The inbox headers are slivers (the default one collapses), so they need a
/// scroll view rather than `Scaffold.appBar`.
Widget _sliverAppBarHarness(Widget sliver) => MaterialApp(
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(body: CustomScrollView(slivers: [sliver])),
  ),
);

Widget _bodyHarness(Widget child) => MaterialApp(
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(body: child),
  ),
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
        _sliverAppBarHarness(
          MessagesSelectionAppBar(
            selectedCount: 3,
            onClear: () {},
            onMarkRead: () => read++,
            onArchive: () => archive++,
            onDelete: () => del++,
            onSelectAll: () {},
            onMarkUnread: () {},
            onBlock: () {},
            onPin: () {},
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
        _sliverAppBarHarness(
          MessagesSelectionAppBar(
            selectedCount: 1,
            onClear: () {},
            onMarkRead: () {},
            onArchive: () {},
            onDelete: () {},
            onSelectAll: () {},
            onMarkUnread: () {},
            onBlock: () => blocked++,
            onPin: () {},
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

  group('showMessageActionOverlay', () {
    Future<void> openOverlay(WidgetTester tester, VoidCallback onCopy) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showMessageActionOverlay(
                  context,
                  message: MessageModel(
                    id: 'm1',
                    threadId: '09120000000',
                    phoneNumber: '09120000000',
                    body: 'سلام دنیا',
                    timestamp: DateTime(2024, 1, 1, 10),
                    type: MessageType.received,
                    status: MessageStatus.delivered,
                  ),
                  anchor: const Rect.fromLTWH(20, 200, 240, 60),
                  isLastInGroup: true,
                  showLinkPreview: false,
                  actions: [
                    MessageAction(
                      icon: Icons.copy_outlined,
                      label: 'کپی',
                      onSelected: onCopy,
                    ),
                  ],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lifts the bubble as selectable text next to the menu', (
      tester,
    ) async {
      await openOverlay(tester, () {});
      // The body is rendered by SelectableText — that is what lets the user
      // drag a selection straight on the zoomed bubble.
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('کپی'), findsOneWidget);
    });

    testWidgets('an action row pops the overlay and fires its callback', (
      tester,
    ) async {
      var copied = 0;
      await openOverlay(tester, () => copied++);
      await tester.tap(find.text('کپی'));
      await tester.pumpAndSettle();
      expect(copied, 1);
      expect(find.byType(SelectableText), findsNothing); // overlay closed
    });
  });
}
