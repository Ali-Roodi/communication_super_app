import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';
import 'package:communication_super_app/features/messages/screens/widgets/message_composer.dart';
import 'package:communication_super_app/features/messages/screens/widgets/schedule_send_sheet.dart';

/// Opens the sheet from a button and hands the result back to the test.
Widget _harness(
  void Function(ScheduleChoice?) onResult, {
  ScheduleChoice? seed,
}) {
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
      // Jitter is a top-level option, reachable for a one-shot too — it used to
      // be nested under «تکرار», which made it unreachable for exactly the
      // case it is most wanted for.
      expect(find.text('پراکندگی زمان ارسال'), findsOneWidget);
      expect(find.text('بدون پراکندگی'), findsOneWidget);
      // «پایان تکرار» still only makes sense once it repeats.
      expect(find.text('پایان تکرار'), findsNothing);
      // Nothing to confirm until a moment is picked.
      expect(find.text('تأیید'), findsNothing);
    });

    testWidgets('a one-shot can carry a jitter window', (tester) async {
      ScheduleChoice? result;
      await tester.pumpWidget(_harness((c) => result = c));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('پراکندگی زمان ارسال'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تا ۶۰ دقیقه'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('فردا صبح'));
      await tester.pumpAndSettle();

      expect(result!.repeat, ScheduleRepeat.none);
      expect(result!.jitter, JitterWindow.sixtyMin);
      expect(result!.at.hour, 8);
    });

    testWidgets('an already-timed sheet confirms without re-picking the time', (
      tester,
    ) async {
      final seeded = DateTime.now().add(const Duration(days: 2));
      ScheduleChoice? result;
      await tester.pumpWidget(
        _harness((c) => result = c, seed: ScheduleChoice(at: seeded)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Editing an armed schedule: change only the jitter, keep the moment.
      await tester.tap(find.text('پراکندگی زمان ارسال'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تا ۱۰ دقیقه'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('تأیید'));
      await tester.pumpAndSettle();

      expect(result!.jitter, JitterWindow.tenMin);
      expect(result!.at, seeded);
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
      // Seeded with a moment, so the sheet leads with it and can be confirmed.
      expect(find.text('زمان ارسال'), findsOneWidget);
      expect(find.text('تأیید'), findsOneWidget);
    });

    test(
      'scheduleDetailSummary names the repeat and the jitter, or neither',
      () {
        final at = DateTime(2026, 6, 1, 18);
        expect(scheduleDetailSummary(ScheduleChoice(at: at)), isNull);
        expect(
          scheduleDetailSummary(
            ScheduleChoice(at: at, jitter: JitterWindow.thirtyMin),
          ),
          'تا ۳۰ دقیقه پراکندگی',
        );
        expect(
          scheduleDetailSummary(
            ScheduleChoice(
              at: at,
              repeat: ScheduleRepeat.daily,
              jitter: JitterWindow.tenMin,
            ),
          ),
          'هر روز · تا ۱۰ دقیقه پراکندگی',
        );
      },
    );
  });

  group('MessageComposer scheduled state', () {
    testWidgets('shows the time banner and a scheduled-send button', (
      tester,
    ) async {
      var cleared = 0;
      var edited = 0;
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
              scheduleSummary: 'هر روز · تا ۳۰ دقیقه پراکندگی',
              onClearSchedule: () => cleared++,
              onEditSchedule: () => edited++,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.schedule_send), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);
      expect(find.textContaining('ارسال در'), findsOneWidget);
      expect(find.textContaining('هر روز'), findsOneWidget);
      expect(find.textContaining('پراکندگی'), findsOneWidget);

      // Tapping the banner edits; only the ✕ clears.
      await tester.tap(find.textContaining('ارسال در'));
      expect(edited, 1);
      expect(cleared, 0);

      await tester.tap(find.byIcon(Icons.close));
      expect(cleared, 1);
    });
  });
}
