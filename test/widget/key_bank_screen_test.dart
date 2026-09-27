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

  testWidgets('an open bank lists directories, groups and numbers', (
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
          groups: [
            GroupSummary(id: '6137c0d2134ef047', name: 'گروه یک', createdAt: 0),
          ],
          ownNumbers: ['09121111111'],
        ),
      ),
    );
    expect(find.text('سازمان آزمایشی'), findsOneWidget);
    expect(find.textContaining('کلید شما: علی'), findsOneWidget);
    expect(find.text('گروه یک'), findsOneWidget);
    expect(find.textContaining('6137-C0D2-134E-F047'), findsOneWidget);
    expect(find.text('وارد کردن فایل کلید'), findsOneWidget);
  });

  testWidgets('the group dialog insists on a long, repeated passphrase', (
    tester,
  ) async {
    await pump(tester, const KeyBankState(status: KeyBankStatus.ready));
    await tester.tap(find.text('افزودن گروه'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'گروه');
    await tester.enterText(fields.at(1), 'کوتاه');
    await tester.enterText(fields.at(2), 'کوتاه');
    await tester.tap(find.text('افزودن').last);
    await tester.pump();
    expect(find.textContaining('دست‌کم'), findsOneWidget);

    await tester.enterText(fields.at(1), 'یک عبارت عبور طولانی');
    await tester.enterText(fields.at(2), 'یک عبارت عبور دیگر');
    await tester.tap(find.text('افزودن').last);
    await tester.pump();
    expect(find.text('دو عبارت عبور یکسان نیستند'), findsOneWidget);

    await tester.enterText(fields.at(2), 'یک عبارت عبور طولانی');
    await tester.tap(find.text('افزودن').last);
    await tester.pumpAndSettle();
    verify(
      () => bloc.add(
        any(
          that: isA<KeyBankAddGroup>()
              .having((e) => e.name, 'name', 'گروه')
              .having(
                (e) => e.passphrase,
                'passphrase',
                'یک عبارت عبور طولانی',
              ),
        ),
      ),
    ).called(1);
  });

  test('ids read in groups of four', () {
    expect(KeyBankScreen.formatId('6137c0d2134ef047'), '6137-C0D2-134E-F047');
  });
}
