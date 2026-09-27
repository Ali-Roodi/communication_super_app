import 'package:flutter/services.dart' show appFlavor;

/// Which APK this is — decided at BUILD time by the Android product flavor.
///
/// هم‌رسان ships as two APKs from one codebase, both with the same
/// applicationId and the same signing key (see `docs/architecture/editions.md`
/// and the Editions block in `android/app/build.gradle.kts`):
///
/// * [commercial] — the store build. The inter-organizational edition is not
///   a third APK: it is this build after an in-app activation, a *runtime*
///   state layered on top of this enum, not a value of it.
/// * [organization] — distributed as a direct APK, never through a store.
enum AppEdition {
  commercial(flavor: 'commercial', label: 'تجاری'),
  organization(flavor: 'organization', label: 'سازمانی');

  const AppEdition({required this.flavor, required this.label});

  /// The Gradle product-flavor name, byte-identical to
  /// `android/app/build.gradle.kts` and to `default-flavor` in pubspec.yaml.
  final String flavor;

  /// What the user sees in «درباره برنامه».
  final String label;

  /// The edition this binary was built as.
  ///
  /// A `const`, so a branch on it is decided by the compiler: code behind
  /// `if (AppEdition.current == AppEdition.organization)` is not merely
  /// skipped in the commercial APK, it is not in it. That is the property a
  /// reviewer of either build is entitled to — "hidden behind an if" is not
  /// "absent".
  static const AppEdition current = kOrganizationBuild
      ? AppEdition.organization
      : AppEdition.commercial;

  /// Maps a flavor name to its edition.
  ///
  /// `null` is the commercial edition: that is what a flavor-less run is
  /// (`flutter test`, which is not an Android build at all). An unknown name
  /// is a build misconfiguration — a Gradle flavor added without a Dart
  /// counterpart — and throws instead of guessing, because guessing
  /// "commercial" for a security edition is the one wrong answer that stays
  /// silent.
  static AppEdition fromFlavor(String? flavor) {
    if (flavor == null) return AppEdition.commercial;
    for (final edition in values) {
      if (edition.flavor == flavor) return edition;
    }
    throw StateError(
      'Unknown build flavor "$flavor". Every Gradle product flavor must have '
      'a matching AppEdition — see docs/architecture/editions.md.',
    );
  }

  /// Fails the launch of a binary whose flavor this code does not know.
  ///
  /// [current] can only tell "organization" from "anything else"; this is
  /// what makes "anything else" mean exactly "commercial". Called first thing
  /// in `main`, so a misconfigured build dies on its first run on a
  /// developer's phone rather than shipping with the wrong feature set.
  static void verifyBuildFlavor() {
    final edition = fromFlavor(appFlavor);
    if (edition != current) {
      // Unreachable while [kOrganizationBuild] and [fromFlavor] agree; kept
      // so that a future edit to one of them cannot drift from the other.
      throw StateError('Edition mismatch: $edition vs $current.');
    }
  }
}

/// True only in the organization APK. Compile-time, see [AppEdition.current].
const bool kOrganizationBuild = appFlavor == 'organization';
