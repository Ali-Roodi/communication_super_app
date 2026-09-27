import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppEdition.fromFlavor', () {
    test('maps each Gradle flavor name to its edition', () {
      expect(AppEdition.fromFlavor('commercial'), AppEdition.commercial);
      expect(AppEdition.fromFlavor('organization'), AppEdition.organization);
    });

    test('a flavor-less run is the commercial edition', () {
      expect(AppEdition.fromFlavor(null), AppEdition.commercial);
    });

    test('an unknown flavor throws instead of guessing', () {
      // A typo of the security edition must not quietly become the store one.
      expect(() => AppEdition.fromFlavor('organisation'), throwsStateError);
      expect(() => AppEdition.fromFlavor('Organization'), throwsStateError);
      expect(() => AppEdition.fromFlavor(''), throwsStateError);
    });
  });

  test('flavor names match android/app/build.gradle.kts', () {
    // Byte-identical to the productFlavors there and to `default-flavor` in
    // pubspec.yaml; a rename on one side only is a build that cannot start.
    expect(AppEdition.values.map((e) => e.flavor).nonNulls, [
      'commercial',
      'organization',
    ]);
  });

  test('inter-organizational is a runtime state, never a build', () {
    // It has no Gradle flavor, so no build can come out as it.
    expect(AppEdition.interOrganization.flavor, isNull);
    expect(AppEdition.current, isNot(AppEdition.interOrganization));
  });

  test('kOrganizationBuild and current agree with the flavor of this run', () {
    expect(kOrganizationBuild, appFlavor == AppEdition.organization.flavor);
    expect(AppEdition.current, AppEdition.fromFlavor(appFlavor));
    expect(AppEdition.verifyBuildFlavor, returnsNormally);
  });
}
