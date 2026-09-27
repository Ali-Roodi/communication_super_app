import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/edition/repositories/activation_repository.dart';
import 'package:communication_super_app/features/edition/screens/inter_org_activation_screen.dart';
import 'package:communication_super_app/features/edition/services/device_identity_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Reference pair (Java-derived, see activation_code_test.dart).
const _androidId = '3f6c1e0b9a27d845';
const _deviceCode = '33b957';

class _FakeIdentity extends DeviceIdentityService {
  _FakeIdentity(this.id);
  final String? id;
  @override
  Future<String?> androidId() async => id;
}

class _MockStorage extends Mock implements FlutterSecureStorage {}

FlutterSecureStorage _memoryStorage() {
  final values = <String, String>{};
  final storage = _MockStorage();
  when(
    () => storage.read(key: any(named: 'key')),
  ).thenAnswer((i) async => values[i.namedArguments[#key] as String]);
  when(
    () => storage.write(
      key: any(named: 'key'),
      value: any(named: 'value'),
    ),
  ).thenAnswer((i) async {
    values[i.namedArguments[#key] as String] =
        i.namedArguments[#value] as String;
  });
  when(() => storage.delete(key: any(named: 'key'))).thenAnswer((i) async {
    values.remove(i.namedArguments[#key] as String);
  });
  return storage;
}

Future<EditionBloc> _pump(WidgetTester tester, {String? androidId}) async {
  final bloc = EditionBloc(
    ActivationRepository(
      identity: _FakeIdentity(androidId),
      storage: _memoryStorage(),
    ),
  )..add(const LoadEdition());
  await tester.pumpWidget(
    BlocProvider.value(
      value: bloc,
      child: const MaterialApp(home: InterOrgActivationScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return bloc;
}

Finder get _activate => find.widgetWithText(FilledButton, 'فعال‌سازی');

void main() {
  testWidgets('shows the device code, Latin and left-to-right', (tester) async {
    await _pump(tester, androidId: _androidId);
    final code = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == _deviceCode,
      ),
    );
    expect(code.textDirection, TextDirection.ltr);
  });

  testWidgets('the button waits for a complete code', (tester) async {
    await _pump(tester, androidId: _androidId);
    expect(tester.widget<FilledButton>(_activate).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '0c310');
    await tester.pump();
    expect(tester.widget<FilledButton>(_activate).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '0c310a2277');
    await tester.pump();
    expect(tester.widget<FilledButton>(_activate).onPressed, isNotNull);
  });

  testWidgets('a wrong code says so; editing clears the error', (tester) async {
    final bloc = await _pump(tester, androidId: _androidId);
    await tester.enterText(find.byType(TextField), 'ba57b3b74f');
    await tester.pump();
    await tester.tap(_activate);
    await tester.pumpAndSettle();
    expect(find.textContaining('کد فعال‌سازی درست نیست'), findsOneWidget);
    expect(bloc.state.edition, AppEdition.commercial);

    await tester.enterText(find.byType(TextField), 'ba57b3b74');
    // The decoration fades the old error out; let it finish.
    await tester.pumpAndSettle();
    expect(find.textContaining('کد فعال‌سازی درست نیست'), findsNothing);
  });

  testWidgets('the right code — typed with Persian digits — activates', (
    tester,
  ) async {
    final bloc = await _pump(tester, androidId: _androidId);
    await tester.enterText(find.byType(TextField), '۰c۳۱-۰a۲۲-۷۷');
    await tester.pump();
    await tester.tap(_activate);
    await tester.pumpAndSettle();
    expect(bloc.state.edition, AppEdition.interOrganization);
    expect(find.text('نسخه بین‌سازمانی فعال است'), findsOneWidget);
    expect(find.text('نسخه بین‌سازمانی فعال شد'), findsOneWidget); // snack

    // …and deactivating, after confirming, goes back to the entry form.
    await tester.tap(find.widgetWithText(OutlinedButton, 'غیرفعال کردن'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'غیرفعال کردن'));
    await tester.pumpAndSettle();
    expect(bloc.state.edition, AppEdition.commercial);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('no device identity: says activation is impossible here', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.textContaining('شناسه این دستگاه خوانده نشد'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
