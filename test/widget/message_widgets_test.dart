import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_bubble.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_list_states.dart';

MessageModel _message({
  required MessageType type,
  required MessageStatus status,
  String body = 'سلام دنیا',
}) => MessageModel(
  id: 'm1',
  threadId: 't1',
  phoneNumber: '09120000000',
  body: body,
  type: type,
  status: status,
  timestamp: DateTime(2026, 1, 1, 12, 30),
);

Widget _wrap(Widget child) => MaterialApp(
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(body: child),
  ),
);

void main() {
  group('MessageBubble', () {
    testWidgets('renders the message body', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: _message(
              type: MessageType.received,
              status: MessageStatus.delivered,
            ),
            isLastInGroup: true,
            selected: false,
            selectionMode: false,
            onTap: () {},
            onLongPress: (_) {},
          ),
        ),
      );
      expect(find.text('سلام دنیا'), findsOneWidget);
    });

    testWidgets('sent + delivered shows the done_all status icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: _message(
              type: MessageType.sent,
              status: MessageStatus.delivered,
            ),
            isLastInGroup: true,
            expanded: true,
            selected: false,
            selectionMode: false,
            onTap: () {},
            onLongPress: (_) {},
          ),
        ),
      );
      expect(find.byIcon(Icons.done_all), findsOneWidget);
    });

    testWidgets('failed message shows a retry icon that fires onRetry', (
      tester,
    ) async {
      var retried = false;
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: _message(
              type: MessageType.sent,
              status: MessageStatus.failed,
            ),
            isLastInGroup: true,
            selected: false,
            selectionMode: false,
            onTap: () {},
            onLongPress: (_) {},
            onRetry: () => retried = true,
          ),
        ),
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await tester.tap(find.byIcon(Icons.error_outline));
      expect(retried, isTrue);
    });

    // The caption under a bubble (time · SIM · «پیامک» · tick) is drawn for the
    // tapped message and nothing else — the same rule for a received message as
    // for a sent one.
    for (final type in MessageType.values) {
      testWidgets('$type bubble hides its caption until it is expanded', (
        tester,
      ) async {
        Widget bubble({required bool expanded}) => _wrap(
          MessageBubble(
            message: _message(type: type, status: MessageStatus.delivered),
            isLastInGroup: true,
            expanded: expanded,
            selected: false,
            selectionMode: false,
            onTap: () {},
            onLongPress: (_) {},
          ),
        );

        await tester.pumpWidget(bubble(expanded: false));
        expect(find.textContaining(':'), findsNothing);

        await tester.pumpWidget(bubble(expanded: true));
        expect(find.textContaining(':'), findsOneWidget);
      });
    }

    testWidgets('selection mode shows the selection check icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: _message(
              type: MessageType.received,
              status: MessageStatus.delivered,
            ),
            isLastInGroup: true,
            selected: true,
            selectionMode: true,
            onTap: () {},
            onLongPress: (_) {},
          ),
        ),
      );
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });

  group('Message list states', () {
    testWidgets('MessagesEmptyState renders the empty hint', (tester) async {
      await tester.pumpWidget(_wrap(const MessagesEmptyState()));
      expect(find.text('هیچ پیامکی موجود نیست'), findsOneWidget);
    });

    testWidgets('MessagesNoResults renders the no-results text', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const MessagesNoResults()));
      expect(find.text('نتیجه‌ای یافت نشد'), findsOneWidget);
    });

    testWidgets(
      'MessagesErrorState shows the message and retry fires callback',
      (tester) async {
        var retried = false;
        await tester.pumpWidget(
          _wrap(
            MessagesErrorState(
              message: 'خطای آزمایشی',
              onRetry: () => retried = true,
            ),
          ),
        );
        expect(find.text('خطای آزمایشی'), findsOneWidget);
        await tester.tap(find.text('تلاش مجدد'));
        expect(retried, isTrue);
      },
    );
  });
}
