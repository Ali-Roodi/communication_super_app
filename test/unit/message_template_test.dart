import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:communication_super_app/core/database/database_helper.dart';
import 'package:communication_super_app/features/messages/models/message_template_model.dart';
import 'package:communication_super_app/features/messages/repositories/template_repository.dart';

const _meeting =
    'جلسه [عنوان] در مورخه [تاریخ] ساعت [زمان] در محل [مکان] برقرار می‌باشد.\n[توضیحات]';

MessageTemplate _template(String body, {bool useContactName = false}) =>
    MessageTemplate(
      id: 't1',
      title: 'قالب',
      body: body,
      useContactName: useContactName,
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('TemplateEngine.fieldsOf', () {
    test('derives one field per placeholder, in order', () {
      final fields = TemplateEngine.fieldsOf(
        'سلام [نام]، [موضوع] چطور پیش رفت؟',
      );

      expect(fields.map((f) => f.label), ['نام', 'موضوع']);
      expect(fields.every((f) => f.kind == TemplateFieldKind.text), isTrue);
    });

    test('merges a date and a time placeholder into one picker', () {
      final fields = TemplateEngine.fieldsOf(_meeting);

      expect(fields.map((f) => f.label), [
        'عنوان',
        'تاریخ و زمان',
        'مکان',
        'توضیحات',
      ]);
      final moment = fields[1];
      expect(moment.kind, TemplateFieldKind.dateTime);
      expect(moment.tokens, ['تاریخ', 'زمان']);
    });

    test('a lone date keeps its own date-only picker', () {
      final fields = TemplateEngine.fieldsOf(
        'پرداخت در تاریخ [تاریخ] انجام شد.',
      );

      expect(fields.single.kind, TemplateFieldKind.date);
    });

    test('a «توضیحات»-shaped name asks for a multi-line box', () {
      final fields = TemplateEngine.fieldsOf('[توضیحات]');

      expect(fields.single.kind, TemplateFieldKind.multiline);
    });

    test('repeats of the same placeholder are asked for once', () {
      final fields = TemplateEngine.fieldsOf('[نام] عزیز، [نام] جان');

      expect(fields, hasLength(1));
    });

    test('an unclosed bracket is not treated as a placeholder', () {
      expect(TemplateEngine.fieldsOf('قیمت [ ۱۲۳'), isEmpty);
    });
  });

  group('TemplateEngine.render', () {
    test('substitutes answers into the body', () {
      final text = TemplateEngine.render(
        _meeting,
        values: {
          'عنوان': 'تست',
          'تاریخ': '۱۴۰۴/۰۴/۰۴',
          'زمان': '۱۴:۱۴',
          'مکان': 'اتاق جلسات',
          'توضیحات': 'همراه کارت شناسایی.',
        },
      );

      expect(
        text,
        'جلسه تست در مورخه ۱۴۰۴/۰۴/۰۴ ساعت ۱۴:۱۴ در محل اتاق جلسات برقرار می‌باشد.\n'
        'همراه کارت شناسایی.',
      );
    });

    test('drops unanswered placeholders and the preposition that led them', () {
      final text = TemplateEngine.render(
        _meeting,
        values: {'عنوان': 'تست', 'مکان': 'اتاق جلسات'},
      );

      // No «[توضیحات]» line, no doubled spaces, and no stranded «در مورخه»/
      // «ساعت» left behind by the unanswered date and time.
      expect(text, 'جلسه تست در محل اتاق جلسات برقرار می‌باشد.');
    });

    test('an unanswered place drops «در محل» with it', () {
      final text = TemplateEngine.render(
        _meeting,
        values: {'عنوان': 'تست', 'تاریخ': '۱۴۰۵/۰۵/۱۰', 'زمان': '۱۶:۲۲'},
      );

      expect(text, 'جلسه تست در مورخه ۱۴۰۵/۰۵/۱۰ ساعت ۱۶:۲۲ برقرار می‌باشد.');
    });

    test('a word that merely ends like a connector is left alone', () {
      final text = TemplateEngine.render('مدیر [نام] را دیدم.');

      expect(text, 'مدیر را دیدم.');
    });

    test('preview keeps the unanswered placeholders visible', () {
      final text = TemplateEngine.render(
        _meeting,
        values: {'عنوان': 'تست'},
        preview: true,
      );

      expect(text, contains('[توضیحات]'));
      expect(text, contains('جلسه تست در مورخه [تاریخ]'));
    });

    test('«درج نام مخاطب» prefixes the contact name, and only when on', () {
      const body = 'جلسه فردا برقرار است.';

      expect(
        TemplateEngine.render(
          body,
          contactName: 'مسعود عظیمی',
          useContactName: true,
        ),
        'مسعود عظیمی عزیز\nجلسه فردا برقرار است.',
      );
      expect(
        TemplateEngine.render(
          body,
          contactName: 'مسعود عظیمی',
          useContactName: false,
        ),
        body,
      );
      // No contact to name → no empty «عزیز» line.
      expect(TemplateEngine.render(body, useContactName: true), body);
    });
  });

  group('MessageTemplate.needsInput', () {
    test('is false for a fixed template with nothing to ask', () {
      expect(_template('با سلام، سپاسگزارم.').needsInput(), isFalse);
    });

    test('is true when the template has placeholders', () {
      expect(_template('سلام [نام]').needsInput(), isTrue);
    });

    test('is true for a fixed template that can greet a known contact', () {
      final template = _template('با سلام.', useContactName: true);

      expect(template.needsInput(hasContactName: true), isTrue);
      expect(template.needsInput(hasContactName: false), isFalse);
    });
  });

  group('TemplateRepository', () {
    setUpAll(() {
      // Run the real schema/migrations against an in-memory SQLite database.
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
    });

    setUp(() => DatabaseHelper.resetForTesting());
    tearDownAll(() => DatabaseHelper.resetForTesting());

    test('a fresh database is seeded with the built-in templates', () async {
      final templates = await TemplateRepository().getTemplates();

      expect(templates, isNotEmpty);
      expect(templates.map((t) => t.title), contains('دعوت‌نامه جلسه'));
      // The seed order is preserved (newest first).
      expect(templates.first.title, 'دعوت‌نامه جلسه');
    });

    test('pinned templates sort above the rest', () async {
      final repo = TemplateRepository();
      final before = await repo.getTemplates();
      final last = before.last;

      await repo.setTemplatesPinned([last.id], true);

      final after = await repo.getTemplates();
      expect(after.first.id, last.id);
      expect(after.first.isPinned, isTrue);
    });

    test('upsert with the same id replaces the row', () async {
      final repo = TemplateRepository();
      await repo.upsertTemplate(
        MessageTemplate(
          id: 'x1',
          title: 'قالب',
          body: 'نسخه ۱',
          updatedAt: DateTime(2026, 1, 1),
        ),
      );
      await repo.upsertTemplate(
        MessageTemplate(
          id: 'x1',
          title: 'قالب',
          body: 'نسخه ۲',
          updatedAt: DateTime(2026, 1, 2),
        ),
      );

      final stored = await repo.getTemplate('x1');
      expect(stored?.body, 'نسخه ۲');
    });

    test('deleting removes the selection', () async {
      final repo = TemplateRepository();
      final all = await repo.getTemplates();
      final ids = all.take(2).map((t) => t.id).toList();

      await repo.deleteTemplates(ids);

      final left = await repo.getTemplates();
      expect(left, hasLength(all.length - 2));
      expect(left.map((t) => t.id), isNot(contains(ids.first)));
    });
  });
}
