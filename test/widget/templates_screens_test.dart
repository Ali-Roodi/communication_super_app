import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:communication_super_app/features/messages/models/template_wire.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/messages/bloc/template_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/template_event.dart';
import 'package:communication_super_app/features/messages/models/message_template_model.dart';
import 'package:communication_super_app/features/messages/repositories/template_repository.dart';
import 'package:communication_super_app/features/messages/screens/template_fill_screen.dart';
import 'package:communication_super_app/features/messages/screens/templates_list_screen.dart';

class _MockRepo extends Mock implements TemplateRepository {}

MessageTemplate _template({
  String id = 't1',
  String title = 'دعوت‌نامه جلسه',
  String body = 'جلسه [عنوان] در محل [مکان] برقرار می‌باشد.',
  bool useContactName = false,
}) => MessageTemplate(
  id: id,
  title: title,
  body: body,
  useContactName: useContactName,
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  group('TemplateFillScreen', () {
    testWidgets('generates one input per placeholder and previews the result', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: TemplateFillScreen(template: _template())),
      );

      expect(find.widgetWithText(TextField, 'عنوان'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'مکان'), findsOneWidget);
      // Unanswered placeholders stay visible in the preview.
      expect(
        find.text('جلسه [عنوان] در محل [مکان] برقرار می‌باشد.'),
        findsOneWidget,
      );

      await tester.enterText(find.widgetWithText(TextField, 'عنوان'), 'تست');
      await tester.pump();

      expect(
        find.text('جلسه تست در محل [مکان] برقرار می‌باشد.'),
        findsOneWidget,
      );
    });

    testWidgets('«تأیید» appears once something is filled and returns the text', (
      tester,
    ) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                final popped = await Navigator.of(context)
                    .push<TemplateFillResult>(
                      MaterialPageRoute(
                        builder: (_) =>
                            TemplateFillScreen(template: _template()),
                      ),
                    );
                result = popped?.text;
              },
              child: const Text('باز کن'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('باز کن'));
      await tester.pumpAndSettle();

      expect(find.text('تأیید'), findsNothing);

      await tester.enterText(find.widgetWithText(TextField, 'عنوان'), 'تست');
      await tester.pump();
      expect(find.text('تأیید'), findsOneWidget);

      await tester.tap(find.text('تأیید'));
      await tester.pumpAndSettle();

      // The unanswered «[مکان]» is dropped, and «در محل» goes with it.
      expect(result, 'جلسه تست برقرار می‌باشد.');
    });

    testWidgets('«درج نام مخاطب» is offered only with a contact, and prefixes', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TemplateFillScreen(
            key: const ValueKey('no-contact'),
            template: _template(body: 'جلسه فردا برقرار است.'),
          ),
        ),
      );
      expect(find.text('درج نام مخاطب'), findsNothing);

      // A different key, so the screen is rebuilt from scratch rather than
      // updated in place (its state is seeded in initState).
      await tester.pumpWidget(
        MaterialApp(
          home: TemplateFillScreen(
            key: const ValueKey('with-contact'),
            template: _template(
              body: 'جلسه فردا برقرار است.',
              useContactName: true,
            ),
            contactName: 'مسعود عظیمی',
          ),
        ),
      );

      expect(find.text('درج نام مخاطب'), findsOneWidget);
      expect(
        find.text('مسعود عظیمی عزیز\nجلسه فردا برقرار است.'),
        findsOneWidget,
      );

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(find.text('جلسه فردا برقرار است.'), findsOneWidget);
    });
  });

  group('TemplatesListScreen (pick mode)', () {
    late _MockRepo repo;

    setUp(() {
      repo = _MockRepo();
      when(() => repo.getTemplates()).thenAnswer(
        (_) async => [
          _template(id: 'fixed', title: 'تشکر', body: 'سپاسگزارم.'),
          _template(id: 'form'),
        ],
      );
    });

    Widget harness({required void Function(TemplateFillResult?) onResult}) {
      final bloc = TemplateBloc(repo)..add(const LoadTemplates());
      // The bloc sits above MaterialApp, as it does in AppBlocProviders: the
      // picker is pushed as a route and would not see a provider scoped inside
      // the navigator.
      return BlocProvider.value(
        value: bloc,
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async => onResult(await showTemplatePicker(context)),
              child: const Text('باز کن'),
            ),
          ),
        ),
      );
    }

    testWidgets('a template with nothing to fill in inserts on one tap', (
      tester,
    ) async {
      TemplateFillResult? result;
      await tester.pumpWidget(harness(onResult: (v) => result = v));
      await tester.tap(find.text('باز کن'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('تشکر'));
      await tester.pumpAndSettle();

      expect(result?.text, 'سپاسگزارم.');
      // Nothing to fill in, so nothing to compress: it ships as plain text.
      expect(result?.wire, isNull);
    });

    testWidgets('a template with placeholders goes through the fill screen', (
      tester,
    ) async {
      TemplateFillResult? result;
      await tester.pumpWidget(harness(onResult: (v) => result = v));
      await tester.tap(find.text('باز کن'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('دعوت‌نامه جلسه'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'مکان'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'مکان'),
        'اتاق جلسات',
      );
      await tester.pump();
      await tester.tap(find.text('تأیید'));
      await tester.pumpAndSettle();

      expect(result?.text, 'جلسه در محل اتاق جلسات برقرار می‌باشد.');
    });
  });
}
