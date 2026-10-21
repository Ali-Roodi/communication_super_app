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
    expect(
      find.textContaining('هنوز فایل کلیدی وارد نشده است'),
      findsOneWidget,
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
