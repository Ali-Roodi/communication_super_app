import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/screens/secure_unlock_screen.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecure extends MockBloc<SecureSessionEvent, SecureSessionState>
    implements SecureSessionBloc {}

/// «باز کردن بخش امن» on a locked screen (the key bank, the encrypted inbox)
/// goes through the same door as the lock icon. It used to push the unlock
/// screen whatever the state: a phone activated before any PIN was set was
/// asked for «رمز برنامه» it did not have, and the key bank could never be
/// opened (found on a fresh install, 1405/07/14).
void main() {
  late _MockSecure secure;

  Future<void> pump(WidgetTester tester, SecureStatus status) async {
    secure = _MockSecure();
    when(() => secure.state).thenReturn(SecureSessionState(status: status));
    whenListen(secure, const Stream<SecureSessionState>.empty());
    // A phone, not the default 800×600 test surface the PIN pad overflows.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      BlocProvider<SecureSessionBloc>.value(
        value: secure,
        child: const MaterialApp(
          home: Scaffold(body: SecureLockedView(message: 'قفل است')),
        ),
      ),
    );
    await tester.tap(find.text('باز کردن بخش امن'));
    await tester.pumpAndSettle();
  }

  testWidgets('no app PIN yet: asks to set one, not for one', (tester) async {
    await pump(tester, SecureStatus.needsPin);
    expect(find.text('رمز برنامه لازم است'), findsOneWidget);
    expect(find.byType(SecureUnlockScreen), findsNothing);
  });

  testWidgets('a 4-digit PIN: asks for a 6-digit one', (tester) async {
    await pump(tester, SecureStatus.pinTooShort);
    expect(find.text('رمز ۶ رقمی لازم است'), findsOneWidget);
    expect(find.byType(SecureUnlockScreen), findsNothing);
  });

  testWidgets('locked: the PIN screen', (tester) async {
    await pump(tester, SecureStatus.locked);
    expect(find.byType(SecureUnlockScreen), findsOneWidget);
  });
}
