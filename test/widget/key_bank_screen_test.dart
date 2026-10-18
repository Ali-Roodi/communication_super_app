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

  testWidgets('an open bank lists its directories and the own key', (
    tester,
  ) async {
    await pump(
      tester,
      const KeyBankState(
        status: KeyBankStatus.ready,
        snapshot: KeyBankSnapshot(
          directories: [
            DirectorySummary(
              id: '01',
              authorityId: 'aa',
              name: 'سازمان آزمایشی',
              serial: 1790000000000,
              memberCount: 3,
              ownName: 'علی',
            ),
          ],
        ),
      ),
    );
    expect(find.text('سازمان آزمایشی'), findsOneWidget);
    expect(find.textContaining('کلید شما: علی'), findsOneWidget);
    expect(find.text('وارد کردن فایل کلید'), findsOneWidget);
    // Nothing of the passphrase groups is left on the screen.
    expect(find.textContaining('گروه'), findsNothing);
    expect(find.textContaining('شماره‌های من'), findsNothing);
  });

  testWidgets('removing a directory asks first', (tester) async {
    await pump(
      tester,
      const KeyBankState(
        status: KeyBankStatus.ready,
        snapshot: KeyBankSnapshot(
          directories: [
            DirectorySummary(
              id: '01',
              authorityId: 'aa',
              name: 'سازمان آزمایشی',
              serial: 1790000000000,
              memberCount: 3,
            ),
          ],
        ),
      ),
    );
    expect(find.textContaining('بدون کلید شما'), findsOneWidget);
    await tester.tap(find.byTooltip('حذف'));
    await tester.pumpAndSettle();
    expect(find.text('حذف دفترچه؟'), findsOneWidget);
    verifyNever(() => bloc.add(any(that: isA<KeyBankRemoveDirectory>())));
  });
}
