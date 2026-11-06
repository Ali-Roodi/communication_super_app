import 'package:communication_super_app/core/edition/activation_code.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/edition/repositories/activation_repository.dart';
import 'package:communication_super_app/features/edition/screens/inter_org_activation_screen.dart';
import 'package:communication_super_app/features/edition/services/device_identity_service.dart';
import 'package:communication_super_app/features/settings/widgets/about_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _androidId = '3f6c1e0b9a27d845';
const _deviceCode = '33b957';

class _FakeIdentity extends DeviceIdentityService {
  @override
  Future<String?> androidId() async => _androidId;
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

Future<void> _pump(WidgetTester tester, {bool activated = false}) async {
  final repository = ActivationRepository(
    identity: _FakeIdentity(),
    storage: _memoryStorage(),
  );
  if (activated) {
    final code = ActivationCode.activationCodeFor(
      _deviceCode,
      target: repository.target,
    );
    expect(await repository.activate(code), isTrue);
  }
  final bloc = EditionBloc(repository)..add(const LoadEdition());
  addTearDown(bloc.close);
  await tester.pumpWidget(
    BlocProvider.value(
      value: bloc,
      child: const MaterialApp(home: Scaffold(body: AboutGroup())),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapVersion(WidgetTester tester, int times) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.text('نسخه'));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'هم‌رسان',
      packageName: 'ir.hamrasan.app',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  group('the store build', () {
    testWidgets('names no other edition', (tester) async {
      await _pump(tester);
      expect(find.text('نوع نسخه'), findsNothing);
      expect(find.textContaining('بین‌سازمانی'), findsNothing);
    });

    testWidgets('four taps on «نسخه» do nothing, and say nothing', (
      tester,
    ) async {
      await _pump(tester);
      await _tapVersion(tester, AboutGroup.activationTaps - 1);
      await tester.pumpAndSettle();
      expect(find.byType(InterOrgActivationScreen), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('the fifth tap opens the activation screen', (tester) async {
      await _pump(tester);
      await _tapVersion(tester, AboutGroup.activationTaps);
      await tester.pumpAndSettle();
      expect(find.byType(InterOrgActivationScreen), findsOneWidget);
    });
  });

  group('after activation', () {
    testWidgets('«نوع نسخه» names the edition and opens the same screen', (
      tester,
    ) async {
      await _pump(tester, activated: true);
      expect(find.text('نوع نسخه'), findsOneWidget);
      expect(find.text('بین‌سازمانی'), findsOneWidget);
      await tester.tap(find.text('نوع نسخه'));
      await tester.pumpAndSettle();
      expect(find.byType(InterOrgActivationScreen), findsOneWidget);
    });
  });
}
