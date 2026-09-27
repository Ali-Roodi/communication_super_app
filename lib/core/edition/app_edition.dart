import 'package:flutter/services.dart' show appFlavor;

/// The three editions of هم‌رسان.
///
/// They ship as two APKs from one codebase, both with the same applicationId
/// and the same signing key (see `docs/architecture/editions.md` and the
/// Editions block in `android/app/build.gradle.kts`):
///
/// * [commercial] — the store build.
/// * [interOrganization] — NOT an APK: the commercial build after the in-app
///   activation code has been entered. It has no Gradle flavor, [current] is
///   never this value, and the edition a running app is actually in comes from
///   `EditionBloc`.
/// * [organization] — distributed as a direct APK, never through a store.
enum AppEdition {
  commercial(flavor: 'commercial', label: 'تجاری'),
  interOrganization(flavor: null, label: 'بین‌سازمانی'),
  organization(flavor: 'organization', label: 'سازمانی');

  const AppEdition({required this.flavor, required this.label});

  /// The Gradle product-flavor name, byte-identical to
  /// `android/app/build.gradle.kts` and to `default-flavor` in pubspec.yaml.
  /// Null for [interOrganization], which is a runtime state, not a build.
  final String? flavor;

  /// What the user sees in «درباره برنامه».
  final String label;

  /// The edition this binary was BUILT as — [commercial] or [organization],
  /// never [interOrganization].
  ///
  /// A `const`, so a branch on it is decided by the compiler: code behind
  /// `if (AppEdition.current == AppEdition.organization)` is not merely
  /// skipped in the commercial APK, it is not in it. That is the property a
  /// reviewer of either build is entitled to — "hidden behind an if" is not
  /// "absent".
  static const AppEdition current = kOrganizationBuild
      ? AppEdition.organization
      : AppEdition.commercial;

  /// Maps a flavor name to the edition it builds.
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
