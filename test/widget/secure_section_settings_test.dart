import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/features/secure/bloc/secure_session_bloc.dart';
import 'package:communication_super_app/features/secure/screens/secure_pin_entry_screen.dart';
import 'package:communication_super_app/features/secure/services/secure_vault_service.dart';
import 'package:communication_super_app/features/settings/screens/secure_section_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecure extends MockBloc<SecureSessionEvent, SecureSessionState>
    implements SecureSessionBloc {}

/// تنظیمات ← امنیت ← «بخش امن»: the section's own PIN and fingerprint.
void main() {
  late _MockSecure secure;

  setUpAll(() => registerFallbackValue(const SecureSessionRefresh()));

  Future<void> pump(WidgetTester tester, SecureSessionState state) async {
    secure = _MockSecure();
    when(() => secure.state).thenReturn(state);
    whenListen(secure, const Stream<SecureSessionState>.empty());
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      BlocProvider<SecureSessionBloc>.value(
        value: secure,
        child: const MaterialApp(home: SecureSectionSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a section: change PIN, fingerprint, delete', (tester) async {
    await pump(
      tester,
      const SecureSessionState(
        status: SecureStatus.locked,
        biometricAvailability: BiometricAvailability.available,
      ),
    );
    expect(find.text('تغییر رمز بخش امن'), findsOneWidget);
    expect(find.text('باز کردن با اثر انگشت'), findsOneWidget);
    expect(find.text('حذف همیشگی بخش امن'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('no section yet: only «ساخت بخش امن»', (tester) async {
    await pump(
      tester,
      const SecureSessionState(status: SecureStatus.notCreated),
    );
    expect(find.text('ساخت بخش امن'), findsOneWidget);
    expect(find.text('تغییر رمز بخش امن'), findsNothing);
    expect(find.text('حذف همیشگی بخش امن'), findsNothing);
  });

  testWidgets('face unlock alone is said to be not enough', (tester) async {
    await pump(
      tester,
      const SecureSessionState(
        status: SecureStatus.locked,
        biometricAvailability: BiometricAvailability.noneEnrolled,
      ),
    );
    expect(find.textContaining('تشخیص چهرهٔ این گوشی'), findsOneWidget);
    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNull);
  });

  testWidgets('turning the fingerprint on asks for the section PIN first', (
    tester,
  ) async {
    await pump(
      tester,
      const SecureSessionState(
        status: SecureStatus.locked,
        biometricAvailability: BiometricAvailability.available,
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(SecurePinEntryScreen), findsOneWidget);
    expect(find.text('رمز بخش امن'), findsWidgets);
    // Nothing is switched on before the PIN.
    verifyNever(
      () => secure.add(any(that: isA<SecureBiometricToggleRequested>())),
    );
  });

  testWidgets('changing the PIN starts with the current one', (tester) async {
    await pump(tester, const SecureSessionState(status: SecureStatus.unlocked));
    await tester.tap(find.text('تغییر رمز بخش امن'));
    await tester.pumpAndSettle();
    expect(find.text('رمز فعلی بخش امن'), findsOneWidget);
  });

  testWidgets('deleting asks first', (tester) async {
    await pump(tester, const SecureSessionState(status: SecureStatus.locked));
    await tester.tap(find.text('حذف همیشگی بخش امن'));
    await tester.pumpAndSettle();
    expect(find.text('حذف بخش امن؟'), findsOneWidget);
    await tester.tap(find.text('حذف همیشگی'));
    await tester.pumpAndSettle();
    verify(() => secure.add(const SecureResetRequested())).called(1);
  });
}
