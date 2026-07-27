import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_composer.dart';
import 'package:communication_super_app/features/messages/screens/widgets/schedule_send_sheet.dart';

/// Opens the sheet from a button and hands the result back to the test.
Widget _harness(void Function(ScheduleChoice?) onResult, {ScheduleChoice? seed}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            onResult(await showScheduleSendSheet(context, initial: seed));
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  group('showScheduleSendSheet', () {
    testWidgets('offers the quick times, a full pick and the repeat rule', (
      tester,
    ) async {
      await tester.pumpWidget(_harness((_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('زمان‌بندی ارسال'), findsOneWidget);
      expect(find.text('فردا صبح'), findsOneWidget);
      expect(find.text('فردا عصر'), findsOneWidget);
      expect(find.text('انتخاب تاریخ و ساعت'), findsOneWidget);
      expect(find.text('تکرار'), findsOneWidget);
      // Repeat detail only appears once the schedule actually repeats.
      expect(find.text('پراکندگی زمان ارسال'), findsNothing);
    });

    testWidgets('a quick tap returns tomorrow at 08:00, no repeat', (
      tester,
    ) async {
      ScheduleChoice? result;
      await tester.pumpWidget(_harness((c) => result = c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('فردا صبح'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.at.hour, 8);
      expect(result!.at.minute, 0);
      expect(result!.at.day, DateTime.now().add(const Duration(days: 1)).day);
      expect(result!.repeat, ScheduleRepeat.none);
    });

    testWidgets('a daily repeat with jitter survives the quick tap', (
      tester,
    ) async {
      ScheduleChoice? result;
      await tester.pumpWidget(_harness((c) => result = c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('تکرار'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('روزانه'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأیید'));
      await tester.pumpAndSettle();

      // The jitter row is now reachable and its choice sticks.
      await tester.tap(find.text('پراکندگی زمان ارسال'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تا ۳۰ دقیقه'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('فردا صبح'));
      await tester.pumpAndSettle();

      expect(result!.repeat, ScheduleRepeat.daily);
      expect(result!.jitter, JitterWindow.thirtyMin);
      expect(result!.at.hour, 8);
    });

    testWidgets('seeds itself from an existing schedule', (tester) async {
      await tester.pumpWidget(
        _harness(
          (_) {},
          seed: ScheduleChoice(
            at: DateTime.now().add(const Duration(days: 2)),
            repeat: ScheduleRepeat.weekly,
            repeatEvery: 2,
            weekdays: const {DateTime.saturday},
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('هر ۲ هفته · ش'), findsOneWidget);
      expect(find.text('پراکندگی زمان ارسال'), findsOneWidget);
    });
  });

  group('MessageComposer scheduled state', () {
    testWidgets('shows the time banner and a scheduled-send button', (
      tester,
    ) async {
      var cleared = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageComposer(
              controller: TextEditingController(text: 'سلام'),
              showStickers: false,
              onToggleStickers: () {},
              onAttach: () {},
              onSend: () {},
              onStickerSelected: (_) {},
              scheduledAt: DateTime(2026, 6, 1, 18),
              scheduleSummary: 'هر روز',
              onClearSchedule: () => cleared++,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.schedule_send), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);
      expect(find.textContaining('ارسال در'), findsOneWidget);
      expect(find.textContaining('هر روز'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      expect(cleared, 1);
    });
  });
}
