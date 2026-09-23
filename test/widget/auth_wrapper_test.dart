import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/models/auth_type.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';
import 'package:communication_super_app/features/authentication/screens/auth_wrapper_screen.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

/// A wrong PIN on the launch screen used to leave a blank page: the wrapper
/// rebuilt on `AuthLoading` / `AuthValidationFailure`, neither of which is the
/// PIN screen, and the keypad never came back.
void main() {
  late _MockAuthRepository repo;

  setUp(() {
    repo = _MockAuthRepository();
    when(() => repo.getAuthType()).thenAnswer((_) async => AuthType.pin);
    when(() => repo.isAuthenticated()).thenAnswer((_) async => false);
    when(() => repo.validatePin(any())).thenAnswer((_) async => false);
  });

  Future<AuthBloc> pump(WidgetTester tester) async {
    final bloc = AuthBloc(repo)..add(const CheckAuthStatus());
    await tester.pumpWidget(
      BlocProvider<AuthBloc>.value(
        value: bloc,
        child: const MaterialApp(home: AuthWrapperScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return bloc;
  }

  Future<void> typePin(WidgetTester tester, List<String> digits) async {
    for (final d in digits) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a wrong PIN keeps the PIN screen and says why', (tester) async {
    final bloc = await pump(tester);
    addTearDown(bloc.close);
    expect(find.text('رمز عبور را وارد کنید'), findsOneWidget);

    await typePin(tester, const ['۱', '۲', '۳', '۴']);

    expect(find.text('رمز عبور را وارد کنید'), findsOneWidget,
        reason: 'the keypad must still be there after a wrong PIN');
    expect(find.text('رمز عبور اشتباه است'), findsOneWidget);
    expect(find.text('۵'), findsOneWidget);
  });

  testWidgets('a second attempt after a wrong one is still checked',
      (tester) async {
    final bloc = await pump(tester);
    addTearDown(bloc.close);

    await typePin(tester, const ['۱', '۲', '۳', '۴']);
    when(() => repo.validatePin('1357')).thenAnswer((_) async => true);
    when(() => repo.setAuthenticated(true)).thenAnswer((_) async {});
    await tester.pump(const Duration(seconds: 5)); // let the snack bar go
    await typePin(tester, const ['۱', '۳', '۵', '۷']);

    verify(() => repo.validatePin('1357')).called(1);
  });
}
