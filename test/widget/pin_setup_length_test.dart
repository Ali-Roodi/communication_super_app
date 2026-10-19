import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_bloc.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_event.dart';
import 'package:communication_super_app/features/authentication/bloc/auth_state.dart';
import 'package:communication_super_app/features/authentication/screens/pin_setup_screen.dart';
import 'package:communication_super_app/features/authentication/screens/widgets/pin_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

const _digits = ['۱', '۲', '۳', '۴'];

/// A new app PIN is 4 digits in every edition; the secure section has a PIN
/// of its own (`SecureUnlockScreen`).
void main() {
  late _MockAuthBloc auth;

  setUp(() {
    auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthAuthenticated(),
    );
  });

  Future<void> type(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tester.tap(find.text(_digits[int.parse(d) - 1]));
      await tester.pump();
    }
  }

  testWidgets('four digits, then the same four again', (tester) async {
    await tester.pumpWidget(
      BlocProvider<AuthBloc>.value(
        value: auth,
        child: const MaterialApp(home: PinSetupScreen(fromSettings: true)),
      ),
    );
    expect(tester.widget<PinDots>(find.byType(PinDots)).length, 4);
    await type(tester, '123');
    expect(find.text('تکرار رمز عبور'), findsNothing);
    await type(tester, '4');
    expect(find.text('تکرار رمز عبور'), findsOneWidget);
    await type(tester, '1234');
    verify(() => auth.add(const SetPin('1234'))).called(1);
  });
}
