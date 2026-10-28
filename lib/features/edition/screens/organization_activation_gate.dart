import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import '../bloc/edition_bloc.dart';
import '../widgets/activation_code_form.dart';

/// Keeps the organization APK closed until this device is activated (matrix
/// row 1, «جلوگیری از توزیع غیرمجاز»): an APK passed on to someone the
/// organization never gave a code to opens on this screen and nothing else.
///
/// It sits below the call coordinator and above the PIN, so nothing of the
/// app — PIN setup, the permission requests, the default-app roles — is
/// reached before the code is in; the roles in particular, so an inactive
/// install never becomes the phone's SMS app or dialer. In the commercial
/// build it is a pass-through the compiler removes ([kOrganizationBuild]).
class OrganizationActivationGate extends StatelessWidget {
  const OrganizationActivationGate({
    super.key,
    required this.child,
    @visibleForTesting this.enabled = kOrganizationBuild,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return BlocBuilder<EditionBloc, EditionState>(
      buildWhen: (a, b) => a.loaded != b.loaded || a.activated != b.activated,
      builder: (context, state) {
        // One secure-storage read and one channel call: blank, not a spinner
        // (nothing on the way in draws one).
        if (!state.loaded) return const Scaffold();
        if (!state.activated) return const OrganizationActivationScreen();
        return child;
      },
    );
  }
}

/// The organization APK's first screen until it is activated.
class OrganizationActivationScreen extends StatelessWidget {
  const OrganizationActivationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppDimensions.paddingLg),
            children: [
              const SizedBox(height: AppDimensions.paddingXl),
              Icon(
                Icons.verified_user_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: AppDimensions.paddingMd),
              Text(
                'فعال‌سازی هم‌رسان سازمانی',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppDimensions.paddingXl),
              const ActivationCodeForm(
                intro:
                    'این نسخه پیش از استفاده باید روی این گوشی فعال شود. کد '
                    'دستگاه زیر را به مسئول سازمان بدهید و کد فعال‌سازی‌ای را '
                    'که می‌گیرید، این‌جا وارد کنید.',
                unavailableText:
                    'شناسه این دستگاه خوانده نشد؛ هم‌رسان سازمانی روی این '
                    'دستگاه فعال نمی‌شود.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
