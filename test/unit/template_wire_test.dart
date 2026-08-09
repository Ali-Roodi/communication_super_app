import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/models/built_in_templates.dart';
import 'package:communication_super_app/features/messages/models/message_template_model.dart';
import 'package:communication_super_app/features/messages/models/template_wire.dart';

MessageTemplate _rowFor(BuiltInTemplate builtIn, {String? body}) =>
    MessageTemplate(
      id: builtIn.id,
      title: builtIn.title,
      body: body ?? builtIn.body,
      useContactName: builtIn.useContactName,
      updatedAt: DateTime(2026, 1, 1),
    );

MessageTemplate _userTemplate(String body) => MessageTemplate(
  id: 'user-1',
  title: 'قالب من',
  body: body,
  updatedAt: DateTime(2026, 1, 1),
);

/// Encodes [values] into [builtIn] the way the fill screen does.
String? _encode(
  BuiltInTemplate builtIn,
  Map<String, String> values, {
  String? greetingName,
  String? bodyOverride,
}) {
  final template = _rowFor(builtIn, body: bodyOverride);
  final rendered = TemplateEngine.render(
    template.body,
    values: values,
    contactName: greetingName,
    useContactName: greetingName != null,
  );
  return TemplateWire.encode(
    template: template,
    values: values,
    greetingName: greetingName,
    renderedText: rendered,
  );
}

void main() {
  final meeting = BuiltInTemplates.byCode('mtg')!;
  final congrats = BuiltInTemplates.byCode('cng')!;
  final thanks = BuiltInTemplates.byCode('thx')!;

  group('catalogue', () {
    test('codes and ids are unique, and every code is short ASCII', () {
      final codes = BuiltInTemplates.all.map((t) => t.code).toList();
      final ids = BuiltInTemplates.all.map((t) => t.id).toList();
      expect(codes.toSet(), hasLength(codes.length));
      expect(ids.toSet(), hasLength(ids.length));
      for (final code in codes) {
        expect(code, matches(RegExp(r'^[a-z0-9]{2,6}$')));
      }
    });

    test('tokens follow the body, in order', () {
      expect(meeting.tokens, ['عنوان', 'تاریخ', 'زمان', 'مکان', 'توضیحات']);
      expect(thanks.isFillable, isFalse);
    });
  });

  group('encode', () {
    test('round-trips the answers and rebuilds the sender\'s text', () {
      const values = {
        'عنوان': 'جلسه هفتگی',
        'تاریخ': '۱۴۰۵/۰۵/۲۰',
        'زمان': '۱۰:۳۰',
        'مکان': 'اتاق ۳',
      };
      final wire = _encode(meeting, values, greetingName: 'علی');
      expect(wire, isNotNull);
      expect(wire, startsWith('[#T1:mtg:1]'));

      final decoded = TemplateWire.decode(wire!);
      expect(decoded, isNotNull);
      expect(decoded!.template.code, 'mtg');
      expect(decoded.greetingName, 'علی');
      expect(decoded.values, values);
      expect(
        decoded.text,
        TemplateEngine.render(
          meeting.body,
          values: values,
          contactName: 'علی',
          useContactName: true,
        ),
      );
    });

    test('is shorter than the prose it replaces', () {
      const values = {'عنوان': 'جلسه هفتگی', 'تاریخ': '۱۴۰۵/۰۵/۲۰'};
      final wire = _encode(meeting, values)!;
      final prose = TemplateEngine.render(meeting.body, values: values);
      expect(wire.length, lessThan(prose.length));
    });

    test('an unanswered placeholder takes its preposition with it', () {
      final wire = _encode(meeting, {'عنوان': 'جلسه هفتگی'})!;
      final text = TemplateWire.decode(wire)!.text;
      // «[مکان]» dropped ⇒ «در محل» must be gone too, and «ساعت» with «[زمان]».
      expect(text.contains('در محل'), isFalse);
      expect(text.contains('ساعت'), isFalse);
      expect(text, contains('جلسه هفتگی'));
    });

    test('no greeting means no greeting flag and no leading segment', () {
      final wire = _encode(meeting, {'عنوان': 'الف'})!;
      expect(wire, startsWith('[#T1:mtg:0]'));
      expect(TemplateWire.decode(wire)!.greetingName, isNull);
    });

    test('separators, backslashes and newlines survive the round trip', () {
      const values = {'مناسبت': r'الف|ب \ ج' '\n' 'د'};
      final wire = _encode(congrats, values)!;
      expect(TemplateWire.decode(wire)!.values['مناسبت'], values['مناسبت']);
    });

    test('a template with no placeholders is not encoded', () {
      expect(_encode(thanks, const {}), isNull);
    });

    test('a template with nothing filled in is not encoded', () {
      expect(_encode(meeting, const {}), isNull);
    });

    test('a user-authored template is never encoded', () {
      final template = _userTemplate('سلام [نام]، خوش آمدید.');
      expect(
        TemplateWire.encode(
          template: template,
          values: const {'نام': 'علی'},
          renderedText: 'سلام علی، خوش آمدید.',
        ),
        isNull,
      );
    });

    // The wire carries a code into the compiled-in catalogue, and the seeded
    // rows are editable. An edited row no longer reconstructs from the constant,
    // so it must fall back to sending its full text — otherwise one side's edit
    // would silently rewrite the other side's incoming message.
    test('an edited built-in falls back to plain text', () {
      expect(
        _encode(
          meeting,
          const {'عنوان': 'الف'},
          bodyOverride: 'جلسه [عنوان] لغو شد.',
        ),
        isNull,
      );
    });

    // `encode` refuses to produce a payload that is not shorter than the prose:
    // shipping an unreadable body to save nothing is a pure loss. No template in
    // the current catalogue can trip that guard (every one of them carries more
    // boilerplate than the 11-character header), so what is asserted here is the
    // contract it exists to keep — if a future built-in is short enough to
    // violate it, this fails.
    test('every fillable built-in is shorter on the wire than in prose', () {
      for (final builtIn in BuiltInTemplates.all.where((t) => t.isFillable)) {
        final values = {
          for (final token in builtIn.tokens) token: 'مقدار آزمایشی',
        };
        final wire = _encode(builtIn, values, greetingName: 'علی');
        expect(wire, isNotNull, reason: builtIn.code);
        final prose = TemplateEngine.render(
          builtIn.body,
          values: values,
          contactName: 'علی',
          useContactName: true,
        );
        expect(wire!.length, lessThan(prose.length), reason: builtIn.code);
      }
    });
  });

  group('decode', () {
    test('ordinary text is not a payload', () {
      for (final body in const [
        'سلام',
        '',
        '[#T]',
        '[#T1:mtg]',
        'پیام [#T1:mtg:0]الف',
      ]) {
        expect(TemplateWire.decode(body), isNull, reason: body);
        expect(TemplateWire.displayText(body), body, reason: body);
      }
    });

    test('an unknown format version renders as its raw text', () {
      const body = '[#T9:mtg:0]الف';
      expect(TemplateWire.decode(body), isNull);
      expect(TemplateWire.displayText(body), body);
    });

    test('an unknown template code renders as its raw text', () {
      const body = '[#T1:zzz:0]الف';
      expect(TemplateWire.decode(body), isNull);
      expect(TemplateWire.displayText(body), body);
    });

    test('a truncated payload fills what it can and drops the rest', () {
      // Multipart SMS lost after the second segment.
      final decoded = TemplateWire.decode('[#T1:mtg:0]جلسه هفتگی|۱۴۰۵/۰۵/۲۰')!;
      expect(decoded.values.keys, ['عنوان', 'تاریخ']);
      expect(decoded.text, isNot(contains('[')));
    });

    test('unanswered placeholders are dropped from the rebuilt text', () {
      final decoded = TemplateWire.decode('[#T1:mtg:0]جلسه هفتگی')!;
      expect(decoded.text, isNot(contains('[')));
      expect(decoded.text, contains('جلسه هفتگی'));
    });

    test('displayText rebuilds a payload and passes text through', () {
      final wire = _encode(congrats, const {'مناسبت': 'سال نو'})!;
      expect(TemplateWire.displayText(wire), contains('سال نو'));
      expect(TemplateWire.displayText(wire), isNot(contains('#T')));
    });
  });
}
