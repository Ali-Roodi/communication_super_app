import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/screens/widgets/emoji_panel.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_composer.dart';
import 'package:communication_super_app/features/messages/screens/widgets/messages_app_bars.dart';
import 'package:communication_super_app/features/messages/screens/widgets/conversation_app_bars.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_action_overlay.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_bubble.dart';

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
      // GSM-7: 160 per single, 153 per part → 200 chars = «۱۰۶/۲». Long SMS is
      // multipart SMS, not MMS, so there is no "MMS" chip.
      expect(find.textContaining('/۲'), findsOneWidget);
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
      // Unicode: 70 per single → 71 chars are already two parts («۶۳/۲»).
      expect(find.textContaining('/۲'), findsOneWidget);
    });

    testWidgets('the field stops growing sooner as the text is scaled up', (
      tester,
    ) async {
      // The cap on the composer's growth is a HEIGHT, so it has to be measured
      // in the size the text is actually drawn at. It was measured at the
      // nominal 16 px, so at «اندازه متن پیام» 2× a ten-line field was twice as
      // tall as the space above the keyboard and the line being typed slid
      // underneath it.
      Future<int> maxLinesAt(double scale) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: const Size(400, 800),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Scaffold(
                    body: MessageComposer(
                      controller: TextEditingController(),
                      showStickers: false,
                      // The Scaffold eats the bottom view inset, so the real
                      // conversation passes the keyboard's height in.
                      keyboardInset: 320,
                      onToggleStickers: () {},
                      onAttach: () {},
                      onSend: () {},
                      onStickerSelected: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        return tester.widget<TextField>(find.byType(TextField)).maxLines!;
      }

      final normal = await maxLinesAt(1);
      final doubled = await maxLinesAt(2);
      expect(normal, greaterThan(1));
      expect(
        doubled,
        lessThan(normal),
        reason: 'twice the line height must buy fewer lines, not the same ten',
      );
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
      // The first emoji of the first category — «اخیر» is absent until the user
      // has picked something, so the panel opens on «لبخند و احساسات».
      final first = emojiCategories.first.emojis.first;
      expect(find.text(first), findsOneWidget);
      await tester.tap(find.text(first));
      expect(picked, first);
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
        // An unsaved number gets BOTH ways to keep it, the way Google Phone
        // and Google Contacts offer them: a new contact, or a number added to
        // somebody already in the address book.
        expect(find.text('ایجاد مخاطب جدید'), findsOneWidget);
        expect(find.text('افزودن به مخاطب موجود'), findsOneWidget);
        await tester.tap(find.text('افزودن به مخاطب موجود'));
        await tester.pumpAndSettle();
        expect(menu, 'addExisting');

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ایجاد مخاطب جدید'));
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
      expect(find.byType(SelectableBubbleText), findsOneWidget);
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
      expect(find.byType(SelectableBubbleText), findsNothing); // closed
    });
  });
}
