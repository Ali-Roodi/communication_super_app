import 'package:communication_super_app/features/contacts/widgets/phone_number_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// «وقتی یکی از ۲ خط یک کاربر رو پیش‌فرض می‌کنیم … باز مودال انتخاب شماره میاد».
///
/// A default number is an answer, not a hint: Google Contacts asks which line
/// only while the contact has none, and once «تنظیم به‌عنوان شماره پیش‌فرض» has
/// been used, تماس/پیام go straight to that line. The sheet used to be shown
/// regardless, with the default merely sorted first and wearing a chip, which
/// made the setting read as decorative.
void main() {
  Future<String?> pick(
    WidgetTester tester, {
    required List<PickablePhone> entries,
  }) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await pickContactNumber(
                  context,
                  entries: entries,
                  title: 'تماس',
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('a contact with a default number is never asked', (tester) async {
    final chosen = await pick(
      tester,
      entries: const [
        PickablePhone(number: '09121112233', label: 'موبایل'),
        PickablePhone(number: '02144556677', label: 'محل کار', isDefault: true),
      ],
    );

    expect(chosen, '02144556677');
    expect(
      find.text('تماس'),
      findsNothing,
      reason: 'the sheet must not open when the question is already answered',
    );
  });

  testWidgets('a contact with no default is still asked', (tester) async {
    await pick(
      tester,
      entries: const [
        PickablePhone(number: '09121112233', label: 'موبایل'),
        PickablePhone(number: '02144556677', label: 'محل کار'),
      ],
    );

    expect(find.text('تماس'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(2));
  });

  testWidgets('one number resolves without a sheet, as before', (tester) async {
    final chosen = await pick(
      tester,
      entries: const [PickablePhone(number: '09121112233')],
    );
    expect(chosen, '09121112233');
    expect(find.text('تماس'), findsNothing);
  });

  testWidgets('two rows both flagged default fall back to asking', (
    tester,
  ) async {
    // `IS_SUPER_PRIMARY` is one row per contact; a contact carrying two has no
    // default worth acting on, and guessing between them would be worse than
    // the question.
    await pick(
      tester,
      entries: const [
        PickablePhone(number: '09121112233', isDefault: true),
        PickablePhone(number: '02144556677', isDefault: true),
      ],
    );
    expect(find.text('تماس'), findsOneWidget);
  });
}
