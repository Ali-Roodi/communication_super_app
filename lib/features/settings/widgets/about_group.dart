import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/features/edition/bloc/edition_bloc.dart';
import 'package:communication_super_app/features/edition/screens/inter_org_activation_screen.dart';
import 'package:communication_super_app/features/settings/screens/privacy_policy_page.dart';

/// «درباره برنامه»: name, version, edition and the privacy policy.
///
/// The version is read off the installed package: a hardcoded string is wrong
/// the moment a release goes out, and the one place it matters is a bug report.
///
/// The store build says nothing about the other editions (design decision,
/// 1405/08/15: a visible «تبدیل به بین‌سازمانی» draws attention). Its activation
/// screen opens from five taps on «نسخه», with no hint on the way; «نوع نسخه»
/// appears only once the app is in a secure edition.
class AboutGroup extends StatefulWidget {
  const AboutGroup({super.key});

  /// Taps on «نسخه» that open the activation screen.
  static const int activationTaps = 5;

  /// A longer pause than this between two taps starts the count again, so taps
  /// spread over a visit to the page do not add up.
  static const Duration activationTapGap = Duration(seconds: 2);

  @override
  State<AboutGroup> createState() => _AboutGroupState();
}

class _AboutGroupState extends State<AboutGroup> {
  String? _version;
  int _versionTaps = 0;
  DateTime? _lastVersionTap;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      // An LTR isolate (LRI … PDI): a version is left-to-right content, and in
      // this RTL row the bidi algorithm reordered its pieces — the
      // organization build's «1.0.0-org (2000000127)» came out as
      // «org (2000000127)-1.0.0».
      setState(
        () => _version =
            '\u2066${PersianUtils.toPersianNumber('${info.version} (${info.buildNumber})')}\u2069',
      );
    });
  }

  void _openActivation() => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const InterOrgActivationScreen()),
  );

  void _onVersionTap() {
    final now = DateTime.now();
    final last = _lastVersionTap;
    final inTime =
        last != null && now.difference(last) <= AboutGroup.activationTapGap;
    _versionTaps = inTime ? _versionTaps + 1 : 1;
    _lastVersionTap = now;
    if (_versionTaps < AboutGroup.activationTaps) return;
    _versionTaps = 0;
    _lastVersionTap = null;
    _openActivation();
  }

  @override
  Widget build(BuildContext context) {
    final edition = context.select<EditionBloc, AppEdition>(
      (bloc) => bloc.state.edition,
    );
    return GroupedList(
      children: [
        const SettingsRow(
          icon: Icons.info_outline,
          title: 'نام برنامه',
          summary: 'هم‌رسان',
        ),
        SettingsRow(
          icon: Icons.tag,
          title: 'نسخه',
          summary: _version ?? '…',
          // Activation exists only in the commercial build; the organization
          // build is its edition by construction and compiles this out. It
          // stays reachable once activated, for «غیرفعال کردن».
          onTap: AppEdition.current == AppEdition.commercial
              ? _onVersionTap
              : null,
        ),
        // Every secure edition installs as the same package and looks the
        // same, so a support call has no other way to learn which one is on
        // the phone.
        if (edition != AppEdition.commercial)
          SettingsRow(
            icon: Icons.verified_outlined,
            title: 'نوع نسخه',
            summary: edition.label,
            onTap: edition == AppEdition.interOrganization
                ? _openActivation
                : null,
          ),
        SettingsRow(
          icon: Icons.privacy_tip_outlined,
          // The store-facing policy, kept inside the app so the text a
          // reviewer reads and the text a user reads are the same one.
          title: 'حریم خصوصی و دسترسی‌ها',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
          ),
        ),
      ],
    );
  }
}
