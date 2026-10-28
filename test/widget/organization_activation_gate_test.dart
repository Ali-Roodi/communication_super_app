import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/edition/activation_code.dart';
import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/edition/repositories/activation_repository.dart';
import 'package:communication_super_app/features/edition/screens/organization_activation_gate.dart';
import 'package:communication_super_app/features/edition/services/device_identity_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Reference device (see activation_code_test.dart).
const _androidId = '3f6c1e0b9a27d845';
const _deviceCode = '33b957';
const _interOrgCode = '0c310a2277';
const _orgCode = 'a3d4ec8c14';

class _FakeIdentity extends DeviceIdentityService {
  _FakeIdentity(this.id);
  final String? id;
  @override
  Future<String?> androidId() async => id;
}

class _MockStorage extends Mock implements FlutterSecureStorage {}

FlutterSecureStorage _memoryStorage([Map<String, String>? initial]) {
  final values = <String, String>{...?initial};
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
  return storage;
}

const _app = Text('the app');

Future<EditionBloc> _pump(
  WidgetTester tester, {
  bool enabled = true,
  Map<String, String>? stored,
  String? androidId = _androidId,
}) async {
  final bloc = EditionBloc(
    ActivationRepository(
      target: ActivationTarget.organization,
      identity: _FakeIdentity(androidId),
      storage: _memoryStorage(stored),
    ),
    build: AppEdition.organization,
  )..add(const LoadEdition());
  await tester.pumpWidget(
    BlocProvider.value(
      value: bloc,
      child: MaterialApp(
        home: OrganizationActivationGate(enabled: enabled, child: _app),
      ),
    ),
  );
  return bloc;
}

Finder get _activate => find.widgetWithText(FilledButton, 'فعال‌سازی');

void main() {
  testWidgets('blank, not a spinner, until the activation is read', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('the app'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('فعال‌سازی هم‌رسان سازمانی'), findsOneWidget);
  });

  testWidgets(
    'not activated: the app is not reached; the device code is shown',
    (tester) async {
      await _pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('the app'), findsNothing);
      expect(find.text(_deviceCode), findsOneWidget);
      // No way around it: no back button, no app bar.
      expect(find.byType(BackButton), findsNothing);
    },
  );

  testWidgets(
    'the inter-organizational code is refused; its own code opens the app',
    (tester) async {
      final bloc = await _pump(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), _interOrgCode);
      await tester.pump();
      await tester.tap(_activate);
      await tester.pumpAndSettle();
      expect(find.textContaining('کد فعال‌سازی درست نیست'), findsOneWidget);
      expect(find.text('the app'), findsNothing);

      await tester.enterText(find.byType(TextField), 'A3D4E-C8C14');
      await tester.pump();
      await tester.tap(_activate);
      await tester.pumpAndSettle();
      expect(find.text('the app'), findsOneWidget);
      expect(bloc.state.activated, isTrue);
      expect(bloc.state.hasSecureFeatures, isTrue);
    },
  );

  testWidgets('an activated install goes straight to the app', (tester) async {
    await _pump(tester, stored: {AppConstants.orgActivationKey: _orgCode});
    await tester.pumpAndSettle();
    expect(find.text('the app'), findsOneWidget);
    expect(find.text('فعال‌سازی هم‌رسان سازمانی'), findsNothing);
  });

  testWidgets(
    'an inter-organizational activation left behind does not open it',
    (tester) async {
      await _pump(
        tester,
        stored: {AppConstants.interOrgActivationKey: _interOrgCode},
      );
      await tester.pumpAndSettle();
      expect(find.text('the app'), findsNothing);
    },
  );

  testWidgets('no device identity: says so, offers no field', (tester) async {
    await _pump(tester, androidId: null);
    await tester.pumpAndSettle();
    expect(find.textContaining('شناسه این دستگاه خوانده نشد'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('the app'), findsNothing);
  });

  testWidgets('the commercial build passes straight through', (tester) async {
    expect(kOrganizationBuild, isFalse);
    await _pump(tester, enabled: false);
    expect(find.text('the app'), findsOneWidget);
  });
}
