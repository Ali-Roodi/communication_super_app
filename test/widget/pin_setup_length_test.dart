import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/screens/pin_setup_screen.dart';
import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockEditionBloc extends MockBloc<EditionEvent, EditionState>
    implements EditionBloc {}

const _digits = ['۱', '۲', '۳', '۴', '۵', '۶'];

void main() {
  late _MockAuthBloc auth;
  late _MockEditionBloc edition;

  setUp(() {
    auth = _MockAuthBloc();
    edition = _MockEditionBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthAuthenticated(),
    );
  });

  Future<void> pump(WidgetTester tester, AppEdition e) async {
    whenListen(
      edition,
      const Stream<EditionState>.empty(),
      initialState: EditionState(edition: e, loaded: true),
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<EditionBloc>.value(value: edition),
        ],
        child: const MaterialApp(home: PinSetupScreen(fromSettings: true)),
      ),
    );
  }

  Future<void> type(WidgetTester tester, int count) async {
    for (var i = 0; i < count; i++) {
      await tester.tap(find.text(_digits[i % _digits.length]));
      await tester.pump();
    }
  }

  testWidgets('a secure edition asks for 6 digits, then confirms them', (
    tester,
  ) async {
    await pump(tester, AppEdition.interOrganization);
    expect(tester.widget<PinDots>(find.byType(PinDots)).length, 6);
    expect(find.text('رمز ۶ رقمی'), findsOneWidget);

    await type(tester, 4);
    expect(find.text('تکرار رمز عبور'), findsNothing); // 4 is not enough
    await type(tester, 2);
    expect(find.text('تکرار رمز عبور'), findsOneWidget);
  });

  testWidgets('the commercial edition keeps its 4-digit PIN', (tester) async {
    await pump(tester, AppEdition.commercial);
    expect(tester.widget<PinDots>(find.byType(PinDots)).length, 4);
    expect(find.text('رمز ۶ رقمی'), findsNothing);
    await type(tester, 4);
    expect(find.text('تکرار رمز عبور'), findsOneWidget);
  });
}
