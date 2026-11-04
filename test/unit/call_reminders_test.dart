import 'package:communication_super_app/features/call_history/screens/widgets/call_reminder_sheet.dart';
import 'package:communication_super_app/features/call_history/services/call_reminders.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Matrix row 39: «یادآور تماس / پیامک» from a row of «اخیر».
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'com.example.communication_super_app/call_reminders',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// A stand-in for `CallReminders.kt`.
  late List<Map<String, Object?>> native;
  late bool alerts;

  setUp(() {
    native = [];
    alerts = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'list':
          return native;
        case 'add':
          final args = (call.arguments as Map).cast<String, Object?>();
          final row = {'id': 'r${native.length}', ...args};
          native.add(row);
          return row;
        case 'remove':
          native.removeWhere((r) => r['id'] == call.arguments['id']);
          return null;
        case 'alertsEnabled':
          return alerts;
      }
      return null;
    });
  });

  tearDown(() async {
    native = [];
    await CallReminders.instance.refresh();
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('reminderQuickTimes', () {
    test('offers this evening while it is more than an hour off', () {
      final morning = DateTime(2026, 11, 4, 10);
      final times = reminderQuickTimes(morning);
      expect(times.map((t) => t.label), contains('امروز عصر'));
      expect(
        times.firstWhere((t) => t.label == 'امروز عصر').at,
        DateTime(2026, 11, 4, 18),
      );

      final late = DateTime(2026, 11, 4, 17, 30);
      expect(
        reminderQuickTimes(late).map((t) => t.label),
        isNot(contains('امروز عصر')),
      );
    });

    test('every time is in the future and tomorrow means the next day', () {
      final now = DateTime(2026, 12, 31, 23, 50);
      final times = reminderQuickTimes(now);
      expect(times.every((t) => t.at.isAfter(now)), isTrue);
      expect(
        times.firstWhere((t) => t.label == 'فردا صبح').at,
        DateTime(2027, 1, 1, 8),
      );
    });
  });

  group('CallReminders', () {
    test('add reports the reminder and refreshes the list', () async {
      final at = DateTime(2026, 11, 4, 16, 30);
      final saved = await CallReminders.instance.add(
        number: '09121234567',
        kind: CallReminderKind.sms,
        at: at,
        name: 'علی',
      );
      expect(saved?.kind, CallReminderKind.sms);
      expect(saved?.at, at);
      final pending = CallReminders.instance.pending.value;
      expect(pending, hasLength(1));
      expect(pending.single.name, 'علی');
      expect(pending.single.number, '09121234567');
    });

    test('remove takes it off the list', () async {
      final saved = await CallReminders.instance.add(
        number: '09121234567',
        kind: CallReminderKind.call,
        at: DateTime(2026, 11, 4, 16, 30),
      );
      await CallReminders.instance.remove(saved!.id);
      expect(CallReminders.instance.pending.value, isEmpty);
    });

    test('a failed read leaves the list as it was', () async {
      await CallReminders.instance.add(
        number: '09121234567',
        kind: CallReminderKind.call,
        at: DateTime(2026, 11, 4, 16, 30),
      );
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'FAILED'),
      );
      await CallReminders.instance.refresh();
      expect(CallReminders.instance.pending.value, hasLength(1));
    });
  });

  group('the sheet', () {
    Widget host(void Function(BuildContext) onTap) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onTap(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          (context) =>
              setCallReminder(context, phone: '09121234567', name: 'علی'),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// Not pumpAndSettle: the snack's countdown ring keeps animating, so settling
    /// would run until the snack has gone.
    Future<void> landed(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    /// Lets the snack's own timer finish.
    Future<void> drain(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    testWidgets('a quick time sets a call reminder by default', (tester) async {
      await open(tester);
      expect(find.text('یادآور برای علی'), findsOneWidget);
      await tester.tap(find.text('۱ ساعت دیگر'));
      await landed(tester);

      expect(native.single['kind'], 'call');
      expect(native.single['number'], '09121234567');
      expect(native.single['name'], 'علی');
      expect(find.textContaining('یادآور تماس'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('the segment switches it to SMS', (tester) async {
      await open(tester);
      await tester.tap(find.text('پیامک'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('۱۵ دقیقه دیگر'));
      await landed(tester);

      expect(native.single['kind'], 'sms');
      expect(find.textContaining('یادآور پیامک'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('«واگرد» takes it back', (tester) async {
      await open(tester);
      await tester.tap(find.text('۱ ساعت دیگر'));
      await landed(tester);
      await tester.tap(find.text('واگرد'));
      await landed(tester);
      expect(native, isEmpty);
      await drain(tester);
    });

    testWidgets('says so when notifications are off', (tester) async {
      alerts = false;
      await open(tester);
      await tester.tap(find.text('۱ ساعت دیگر'));
      await landed(tester);
      expect(find.textContaining('اعلان‌های برنامه خاموش است'), findsOneWidget);
      expect(native, hasLength(1));
      await drain(tester);
    });

    testWidgets('backing out sets nothing', (tester) async {
      await open(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(native, isEmpty);
    });
  });

  group('«یادآورها» on «اخیر»', () {
    Widget entry() => const MaterialApp(
      home: Scaffold(
        body: Directionality(
          textDirection: TextDirection.rtl,
          child: CallRemindersEntry(),
        ),
      ),
    );

    testWidgets('is absent with nothing pending', (tester) async {
      await tester.pumpWidget(entry());
      expect(find.text('یادآورها'), findsNothing);
    });

    testWidgets('lists them and removes one; the sheet closes on the last', (
      tester,
    ) async {
      await tester.pumpWidget(entry());
      await tester.runAsync(
        () => CallReminders.instance.add(
          number: '09121234567',
          kind: CallReminderKind.sms,
          at: DateTime.now().add(const Duration(hours: 2)),
          name: 'علی',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('یادآورها'), findsOneWidget);
      expect(find.text('۱'), findsOneWidget);

      await tester.tap(find.text('یادآورها'));
      await tester.pumpAndSettle();
      expect(find.text('علی'), findsOneWidget);
      expect(find.textContaining('پیامک ·'), findsOneWidget);

      await tester.tap(find.byTooltip('حذف یادآور'));
      await tester.pumpAndSettle();
      expect(find.text('علی'), findsNothing);
      expect(find.text('یادآورها'), findsNothing);
    });
  });
}
