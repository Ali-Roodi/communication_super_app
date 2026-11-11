import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/features/keybank/bloc/key_bank_bloc.dart';
import 'package:communication_super_app/features/keybank/screens/key_bank_screen.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockKeyBank extends MockBloc<KeyBankEvent, KeyBankState>
    implements KeyBankBloc {}

void main() {
  late _MockKeyBank bloc;

  setUpAll(() => registerFallbackValue(const KeyBankRefresh()));

  setUp(() => bloc = _MockKeyBank());

  Future<void> pump(WidgetTester tester, KeyBankState state) async {
    whenListen(bloc, const Stream<KeyBankState>.empty(), initialState: state);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider<KeyBankBloc>.value(
          value: bloc,
          child: const KeyBankScreen(),
        ),
      ),
    );
  }

  testWidgets('a locked section shows nothing but the way to open it', (
    tester,
  ) async {
    await pump(tester, const KeyBankState());
    expect(find.text('باز کردن بخش امن'), findsOneWidget);
    expect(find.text('وارد کردن فایل کلید'), findsNothing);
  });

  const ready = KeyBankState(
    status: KeyBankStatus.ready,
    snapshot: KeyBankSnapshot(
      keys: [
        OwnKeySummary(
          keyId: '0101010101010101',
          authorityId: 'aa',
          phone: '09121111111',
          generation: 1,
          importedAt: 1790000000000,
        ),
      ],
    ),
  );

  testWidgets('an open bank shows the own key and nobody else', (tester) async {
    await pump(tester, ready);
    expect(find.text('کلید شما'), findsOneWidget);
    expect(find.textContaining('۰۹۱۲'), findsOneWidget);
    expect(find.textContaining('نسل کلید ۱'), findsOneWidget);
    expect(find.text('وارد کردن فایل کلید'), findsOneWidget);
    // No list of members, no member count, no update file.
    expect(find.textContaining('دفترچه'), findsNothing);
    expect(find.textContaining('عضو'), findsNothing);
    expect(find.textContaining('update'), findsNothing);
  });

  testWidgets('an empty bank says what is missing', (tester) async {
    await pump(tester, const KeyBankState(status: KeyBankStatus.ready));
    expect(find.textContaining('هنوز کلیدی وارد نشده است'), findsOneWidget);
  });

  group('«ساختن کلید با کد»', () {
    Future<void> open(WidgetTester tester) async {
      await pump(tester, ready);
      await tester.tap(find.text('ساختن کلید با کد'));
      await tester.pumpAndSettle();
    }

    TextButton build(WidgetTester tester) => tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'ساختن کلید'),
    );

    testWidgets('needs all 16 characters and a password', (tester) async {
      await open(tester);
      expect(build(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'ABCD-EFGH-2345');
      await tester.enterText(find.byType(TextField).last, 'PW');
      await tester.pump();
      expect(build(tester).onPressed, isNull);

      await tester.enterText(
        find.byType(TextField).first,
        'ABCD-EFGH-2345-6789',
      );
      await tester.pump();
      expect(build(tester).onPressed, isNotNull);

      await tester.enterText(find.byType(TextField).last, '');
      await tester.pump();
      expect(build(tester).onPressed, isNull);
    });

    testWidgets('hands both to the bloc, and hides only the password', (
      tester,
    ) async {
      await open(tester);
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields.first.obscureText, isFalse);
      expect(fields.last.obscureText, isTrue);

      await tester.enterText(
        find.byType(TextField).first,
        'abcd efgh 2345 6789',
      );
      await tester.enterText(find.byType(TextField).last, 'PW');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'ساختن کلید'));
      await tester.pumpAndSettle();

      final added = verify(() => bloc.add(captureAny())).captured.single;
      expect(added, isA<KeyBankImportCode>());
      // Laid out by the field as the panel prints it; the dashes mean
      // nothing to `MemberCode`.
      expect((added as KeyBankImportCode).code, 'ABCD-EFGH-2345-6789');
      expect(added.password, 'PW');
    });

    testWidgets('both fields put the dashes in by themselves', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'abcd2345wxyz');
      await tester.enterText(
        find.byType(TextField).last,
        'pqrs2345wxyzabcd6789extra',
      );
      await tester.pump();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields.first.controller!.text, 'ABCD-2345-WXYZ-');
      expect(fields.last.controller!.text, 'PQRS-2345-WXYZ-ABCD-6789');
    });

    testWidgets('cancelling builds nothing', (tester) async {
      await open(tester);
      await tester.tap(find.text('انصراف'));
      await tester.pumpAndSettle();
      verifyNever(() => bloc.add(any()));
    });
  });

  test('a wrong code says nothing was built', () {
    expect(
      KeyBankScreen.noticeText(KeyBankNotice.wrongCode),
      contains('ساخته نشد'),
    );
  });

  testWidgets('removing the key asks first', (tester) async {
    await pump(tester, ready);
    await tester.tap(find.byTooltip('حذف'));
    await tester.pumpAndSettle();
    expect(find.text('حذف کلید؟'), findsOneWidget);
    verifyNever(() => bloc.add(any(that: isA<KeyBankRemoveKey>())));
  });
}
