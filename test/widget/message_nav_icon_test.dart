import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/core/navigation/widgets/message_nav_icon.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('MessageNavIcon unread badge', () {
    testWidgets('hides the badge label when there are no unread messages', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const MessageNavIcon(unread: 0, filled: false)),
      );

      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.isLabelVisible, isFalse);
    });

    testWidgets('shows the exact count for small numbers', (tester) async {
      await tester.pumpWidget(
        _wrap(const MessageNavIcon(unread: 7, filled: false)),
      );

      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.isLabelVisible, isTrue);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('caps the label at "99+" above 99', (tester) async {
      await tester.pumpWidget(
        _wrap(const MessageNavIcon(unread: 150, filled: false)),
      );

      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('uses the filled icon when active', (tester) async {
      await tester.pumpWidget(
        _wrap(const MessageNavIcon(unread: 0, filled: true)),
      );
      expect(find.byIcon(Icons.chat_bubble), findsOneWidget);

      await tester.pumpWidget(
        _wrap(const MessageNavIcon(unread: 0, filled: false)),
      );
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    });
  });
}
