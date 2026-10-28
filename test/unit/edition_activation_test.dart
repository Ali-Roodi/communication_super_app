import 'package:bloc_test/bloc_test.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';
import 'package:communication_super_app/core/edition/activation_code.dart';
import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/edition/repositories/activation_repository.dart';
import 'package:communication_super_app/features/edition/services/device_identity_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Reference pair from `activation_code_test.dart` (Java-derived).
const _androidId = '3f6c1e0b9a27d845';
const _deviceCode = '33b957';
const _activationCode = '0c310a2277';

/// The organization APK's code for the same device — pinned to the same
/// value in `tools/keybank`'s `ActivationTest`.
const _orgActivationCode = 'a3d4ec8c14';

class _FakeIdentity extends DeviceIdentityService {
  _FakeIdentity(this.id);
  String? id;
  @override
  Future<String?> androidId() async => id;
}

class _MockStorage extends Mock implements FlutterSecureStorage {}

/// An in-memory secure storage behind the mock, so the repository is tested
/// against real read/write/delete semantics.
_MockStorage _storage({Map<String, String>? initial, bool failWrites = false}) {
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
    if (failWrites) throw Exception('keystore unavailable');
    values[i.namedArguments[#key] as String] =
        i.namedArguments[#value] as String;
  });
  when(() => storage.delete(key: any(named: 'key'))).thenAnswer((i) async {
    values.remove(i.namedArguments[#key] as String);
  });
  return storage;
}

void main() {
  group('ActivationRepository', () {
    test('the device code is derived from ANDROID_ID', () async {
      final repo = ActivationRepository(
        identity: _FakeIdentity(_androidId),
        storage: _storage(),
      );
      expect(await repo.deviceCode(), _deviceCode);
    });

    test('no ANDROID_ID: no device code, cannot activate', () async {
      final repo = ActivationRepository(
        identity: _FakeIdentity(null),
        storage: _storage(),
      );
      expect(await repo.deviceCode(), isNull);
      expect(await repo.activate(_activationCode), isFalse);
      expect(await repo.isActivated(), isFalse);
    });

    test('a wrong code is refused and nothing is stored', () async {
      final storage = _storage();
      final repo = ActivationRepository(
        identity: _FakeIdentity(_androidId),
        storage: storage,
      );
      expect(await repo.activate('ba57b3b74f'), isFalse);
      expect(await repo.isActivated(), isFalse);
      verifyNever(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );
    });

    test('the right code activates, stored in normalized form', () async {
      final storage = _storage();
      final repo = ActivationRepository(
        identity: _FakeIdentity(_androidId),
        storage: storage,
      );
      expect(await repo.activate('0C31-0A22-77'), isTrue);
      expect(await repo.isActivated(), isTrue);
      verify(
        () => storage.write(
          key: AppConstants.interOrgActivationKey,
          value: _activationCode,
        ),
      ).called(1);
    });

    test('deactivate forgets the code', () async {
      final repo = ActivationRepository(
        identity: _FakeIdentity(_androidId),
        storage: _storage(),
      );
      await repo.activate(_activationCode);
      await repo.deactivate();
      expect(await repo.isActivated(), isFalse);
    });

    test('a stored code does not travel to another device', () async {
      // Storage copied to another phone, or kept across a factory reset
      // (which regenerates ANDROID_ID): the code is re-verified, not trusted.
      final repo = ActivationRepository(
        identity: _FakeIdentity('9774d56d682e549c'),
        storage: _storage(
          initial: {AppConstants.interOrgActivationKey: _activationCode},
        ),
      );
      expect(await repo.isActivated(), isFalse);
    });

    test('a forged stored value is not an activation', () async {
      final repo = ActivationRepository(
        identity: _FakeIdentity(_androidId),
        storage: _storage(
          initial: {AppConstants.interOrgActivationKey: 'true'},
        ),
      );
      expect(await repo.isActivated(), isFalse);
    });

    test('an unreadable store reads as not activated', () async {
      final storage = _MockStorage();
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenThrow(Exception('bad padding'));
      final repo = ActivationRepository(
        identity: _FakeIdentity(_androidId),
        storage: storage,
      );
      expect(await repo.isActivated(), isFalse);
    });
  });

  group('EditionBloc (commercial build)', () {
    test('this test run is the commercial build', () {
      // The organization branch is decided at compile time and cannot be
      // exercised here; see app_edition_test.dart.
      expect(AppEdition.current, AppEdition.commercial);
    });

    blocTest<EditionBloc, EditionState>(
      'loads as commercial with the device code',
      build: () => EditionBloc(
        ActivationRepository(
          identity: _FakeIdentity(_androidId),
          storage: _storage(),
        ),
      ),
      act: (bloc) => bloc.add(const LoadEdition()),
      expect: () => [
        const EditionState(
          edition: AppEdition.commercial,
          deviceCode: _deviceCode,
          loaded: true,
        ),
      ],
    );

    blocTest<EditionBloc, EditionState>(
      'loads as inter-organizational when a valid code is stored',
      build: () => EditionBloc(
        ActivationRepository(
          identity: _FakeIdentity(_androidId),
          storage: _storage(
            initial: {AppConstants.interOrgActivationKey: _activationCode},
          ),
        ),
      ),
      act: (bloc) => bloc.add(const LoadEdition()),
      expect: () => [
        const EditionState(
          edition: AppEdition.interOrganization,
          activated: true,
          deviceCode: _deviceCode,
          loaded: true,
        ),
      ],
      verify: (bloc) => expect(bloc.state.hasSecureFeatures, isTrue),
    );

    blocTest<EditionBloc, EditionState>(
      'a device with no identity says so',
      build: () => EditionBloc(
        ActivationRepository(
          identity: _FakeIdentity(null),
          storage: _storage(),
        ),
      ),
      act: (bloc) => bloc.add(const LoadEdition()),
      expect: () => [
        const EditionState(
          edition: AppEdition.commercial,
          loaded: true,
          deviceCodeUnavailable: true,
        ),
      ],
    );

    blocTest<EditionBloc, EditionState>(
      'each wrong code is a new failure; the right one activates and clears it',
      build: () => EditionBloc(
        ActivationRepository(
          identity: _FakeIdentity(_androidId),
          storage: _storage(),
        ),
      ),
      act: (bloc) async {
        bloc.add(const LoadEdition());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ActivateEdition('ba57b3b74f'));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ActivateEdition('ba57b3b74f'));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ActivateEdition('۰c۳۱۰a۲۲۷۷'));
      },
      skip: 1, // the load
      expect: () => [
        isA<EditionState>().having((s) => s.checking, 'checking', isTrue),
        isA<EditionState>()
            .having((s) => s.failedAttempts, 'failedAttempts', 1)
            .having(
              (s) => s.lastFailure,
              'lastFailure',
              ActivationFailure.wrongCode,
            ),
        isA<EditionState>().having((s) => s.checking, 'checking', isTrue),
        isA<EditionState>().having(
          (s) => s.failedAttempts,
          'failedAttempts',
          2,
        ),
        isA<EditionState>().having((s) => s.checking, 'checking', isTrue),
        isA<EditionState>()
            .having((s) => s.edition, 'edition', AppEdition.interOrganization)
            .having((s) => s.lastFailure, 'lastFailure', isNull)
            .having((s) => s.failedAttempts, 'failedAttempts', 0)
            .having((s) => s.checking, 'checking', isFalse),
      ],
    );

    blocTest<EditionBloc, EditionState>(
      'a right code that cannot be saved is a save failure, not a wrong code',
      build: () => EditionBloc(
        ActivationRepository(
          identity: _FakeIdentity(_androidId),
          storage: _storage(failWrites: true),
        ),
      ),
      act: (bloc) async {
        bloc.add(const LoadEdition());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ActivateEdition(_activationCode));
      },
      skip: 2, // the load and "checking"
      expect: () => [
        isA<EditionState>()
            .having((s) => s.edition, 'edition', AppEdition.commercial)
            .having(
              (s) => s.lastFailure,
              'lastFailure',
              ActivationFailure.saveFailed,
            )
            .having((s) => s.checking, 'checking', isFalse),
      ],
    );

    blocTest<EditionBloc, EditionState>(
      'deactivating returns to the commercial edition',
      build: () => EditionBloc(
        ActivationRepository(
          identity: _FakeIdentity(_androidId),
          storage: _storage(
            initial: {AppConstants.interOrgActivationKey: _activationCode},
          ),
        ),
      ),
      act: (bloc) async {
        bloc.add(const LoadEdition());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const DeactivateInterOrganization());
      },
      skip: 1,
      expect: () => [
        isA<EditionState>()
            .having((s) => s.edition, 'edition', AppEdition.commercial)
            .having((s) => s.hasSecureFeatures, 'hasSecureFeatures', isFalse),
      ],
    );
  });

  group('ActivationRepository (organization target)', () {
    ActivationRepository repo(_MockStorage storage) => ActivationRepository(
      target: ActivationTarget.organization,
      identity: _FakeIdentity(_androidId),
      storage: storage,
    );

    test(
      'the inter-organizational code does not open the organization APK',
      () async {
        final storage = _storage();
        expect(await repo(storage).activate(_activationCode), isFalse);
        verifyNever(
          () => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        );
      },
    );

    test('its own code activates, stored under its own key', () async {
      final storage = _storage();
      expect(await repo(storage).activate('A3D4E-C8C14'), isTrue);
      expect(await repo(storage).isActivated(), isTrue);
      verify(
        () => storage.write(
          key: AppConstants.orgActivationKey,
          value: _orgActivationCode,
        ),
      ).called(1);
    });

    test(
      'an inter-organizational activation left behind is not read',
      () async {
        // The organization APK installed over an activated commercial one keeps
        // its secure storage — that code must not open it.
        final storage = _storage(
          initial: {AppConstants.interOrgActivationKey: _activationCode},
        );
        expect(await repo(storage).isActivated(), isFalse);
      },
    );

    test(
      'its code under the inter-organizational key is not read either',
      () async {
        final storage = _storage(
          initial: {AppConstants.interOrgActivationKey: _orgActivationCode},
        );
        expect(await repo(storage).isActivated(), isFalse);
      },
    );

    test('the commercial build refuses the organization code', () async {
      final commercial = ActivationRepository(
        identity: _FakeIdentity(_androidId),
        storage: _storage(),
      );
      expect(commercial.target, ActivationTarget.interOrganization);
      expect(await commercial.activate(_orgActivationCode), isFalse);
    });
  });

  group('EditionBloc (organization build)', () {
    EditionBloc bloc(_MockStorage storage) => EditionBloc(
      ActivationRepository(
        target: ActivationTarget.organization,
        identity: _FakeIdentity(_androidId),
        storage: storage,
      ),
      build: AppEdition.organization,
    );

    test('before loading it has no secure features', () {
      expect(bloc(_storage()).state.hasSecureFeatures, isFalse);
    });

    blocTest<EditionBloc, EditionState>(
      'loads as organization, not activated, with the device code',
      build: () => bloc(_storage()),
      act: (bloc) => bloc.add(const LoadEdition()),
      expect: () => [
        const EditionState(
          edition: AppEdition.organization,
          deviceCode: _deviceCode,
          loaded: true,
        ),
      ],
      verify: (bloc) => expect(bloc.state.hasSecureFeatures, isFalse),
    );

    blocTest<EditionBloc, EditionState>(
      'loads activated when its code is stored',
      build: () => bloc(
        _storage(initial: {AppConstants.orgActivationKey: _orgActivationCode}),
      ),
      act: (bloc) => bloc.add(const LoadEdition()),
      expect: () => [
        const EditionState(
          edition: AppEdition.organization,
          activated: true,
          deviceCode: _deviceCode,
          loaded: true,
        ),
      ],
      verify: (bloc) => expect(bloc.state.hasSecureFeatures, isTrue),
    );

    blocTest<EditionBloc, EditionState>(
      'the inter-organizational code fails; its own code activates, edition unchanged',
      build: () => bloc(_storage()),
      act: (bloc) async {
        bloc.add(const LoadEdition());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ActivateEdition(_activationCode));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ActivateEdition(_orgActivationCode));
      },
      skip: 1,
      expect: () => [
        isA<EditionState>().having((s) => s.checking, 'checking', isTrue),
        isA<EditionState>()
            .having((s) => s.activated, 'activated', isFalse)
            .having(
              (s) => s.lastFailure,
              'lastFailure',
              ActivationFailure.wrongCode,
            ),
        isA<EditionState>().having((s) => s.checking, 'checking', isTrue),
        isA<EditionState>()
            .having((s) => s.edition, 'edition', AppEdition.organization)
            .having((s) => s.activated, 'activated', isTrue)
            .having((s) => s.hasSecureFeatures, 'hasSecureFeatures', isTrue)
            .having((s) => s.lastFailure, 'lastFailure', isNull),
      ],
    );

    blocTest<EditionBloc, EditionState>(
      'there is no deactivating an organization APK',
      build: () => bloc(
        _storage(initial: {AppConstants.orgActivationKey: _orgActivationCode}),
      ),
      act: (bloc) async {
        bloc.add(const LoadEdition());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const DeactivateInterOrganization());
      },
      skip: 1,
      expect: () => <EditionState>[],
      verify: (bloc) => expect(bloc.state.activated, isTrue),
    );
  });
}
