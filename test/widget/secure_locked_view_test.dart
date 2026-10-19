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
/// goes through the same door as the lock icon, to the section's own PIN —
/// never the app PIN, which the section has nothing to do with.
void main() {
  late _MockSecure secure;

  setUpAll(() => registerFallbackValue(const SecureSessionRefresh()));

  Future<void> pump(
    WidgetTester tester,
    SecureStatus status, {
    bool biometricOn = false,
  }) async {
    secure = _MockSecure();
    when(
      () => secure.state,
    ).thenReturn(SecureSessionState(status: status, biometricOn: biometricOn));
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

  Future<void> type(WidgetTester tester, String digits) async {
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    for (final d in digits.split('')) {
      await tester.tap(find.text(persian[int.parse(d)]));
      await tester.pump();
    }
  }

  testWidgets('no section yet: its own PIN is set, typed twice', (
    tester,
  ) async {
    await pump(tester, SecureStatus.notCreated);
    expect(find.byType(SecureUnlockScreen), findsOneWidget);
    expect(find.text('رمز بخش امن را تعیین کنید'), findsOneWidget);
    expect(find.textContaining('جدا از رمز برنامه'), findsOneWidget);
    // Nothing to forget yet.
    expect(find.text('رمز بخش امن را فراموش کرده‌ام'), findsNothing);

    await type(tester, '246810');
    expect(find.text('رمز را دوباره وارد کنید'), findsOneWidget);
    verifyNever(() => secure.add(any()));

    await type(tester, '246811');
    expect(find.text('دو رمز یکسان نبودند؛ دوباره تعیین کنید'), findsOneWidget);
    expect(find.text('رمز بخش امن را تعیین کنید'), findsOneWidget);
    verifyNever(() => secure.add(any()));

    await type(tester, '246810');
    await type(tester, '246810');
    verify(() => secure.add(const SecureCreateRequested('246810'))).called(1);
  });

  testWidgets('locked: the section PIN, six digits', (tester) async {
    await pump(tester, SecureStatus.locked);
    expect(find.text('رمز بخش امن را وارد کنید'), findsOneWidget);
    await type(tester, '24681');
    verifyNever(() => secure.add(any()));
    await type(tester, '0');
    verify(() => secure.add(const SecureUnlockRequested('246810'))).called(1);
  });

  testWidgets('a forgotten section PIN: warned, then the section is reset', (
    tester,
  ) async {
    await pump(tester, SecureStatus.locked);
    await tester.tap(find.text('رمز بخش امن را فراموش کرده‌ام'));
    await tester.pumpAndSettle();
    expect(find.textContaining('راه بازیابی ندارد'), findsOneWidget);

    await tester.tap(find.text('انصراف'));
    await tester.pumpAndSettle();
    verifyNever(() => secure.add(any()));

    await tester.tap(find.text('رمز بخش امن را فراموش کرده‌ام'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف و ساخت دوباره'));
    await tester.pumpAndSettle();
    verify(() => secure.add(const SecureResetRequested())).called(1);
  });

  testWidgets('broken: offers the reset right there', (tester) async {
    await pump(tester, SecureStatus.broken);
    expect(find.text('بخش امن باز نمی‌شود'), findsOneWidget);
    expect(find.byIcon(Icons.backspace_outlined), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'حذف و ساخت دوباره'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'حذف و ساخت دوباره'));
    await tester.pumpAndSettle();
    verify(() => secure.add(const SecureResetRequested())).called(1);
  });

  testWidgets('the fingerprint key is there only when it is on', (
    tester,
  ) async {
    await pump(tester, SecureStatus.locked);
    expect(find.byIcon(Icons.fingerprint), findsNothing);
  });

  testWidgets('with it on, the key asks the section for the fingerprint', (
    tester,
  ) async {
    await pump(tester, SecureStatus.locked, biometricOn: true);
    await tester.pump();
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
    clearInteractions(secure);
    await tester.tap(find.byIcon(Icons.fingerprint));
    await tester.pump();
    verify(
      () => secure.add(any(that: isA<SecureBiometricUnlockRequested>())),
    ).called(greaterThanOrEqualTo(1));
  });
}
